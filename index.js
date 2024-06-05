import express from 'express';
import pg from 'pg';
import redis from 'redis';
import { SecretClient } from '@azure/keyvault-secrets';
import { DefaultAzureCredential } from '@azure/identity';
import dotenv from 'dotenv';

const { Pool } = pg;

dotenv.config();
const isProd = process.env.NODE_ENV === 'production';

async function main() {
  let keyVaultCredential;
  let keyVaultName;
  let keyVaultUrl;
  let keyVaultClient;

  if (isProd) {
    keyVaultCredential = new DefaultAzureCredential();
    keyVaultName = process.env.KEY_VAULT_NAME;
    if (!keyVaultName) throw new Error('KEY_VAULT_NAME is empty');
    keyVaultUrl = 'https://' + keyVaultName + '.vault.azure.net';
    keyVaultClient = new SecretClient(keyVaultUrl, keyVaultCredential);
  }

  const app = express();
  app.use(express.json());

  const poolConfig = {
    user: isProd
      ? (await keyVaultClient.getSecret('PGUSER')).value
      : process.env.PGUSER,
    host: isProd
      ? (await keyVaultClient.getSecret('PGHOST')).value
      : process.env.PGHOST,
    database: isProd
      ? (await keyVaultClient.getSecret('PGDATABASE')).value
      : process.env.PGDATABASE,
    password: isProd
      ? (await keyVaultClient.getSecret('PGPASSWORD')).value
      : process.env.PGPASSWORD,
    port: isProd
      ? (await keyVaultClient.getSecret('PGPORT')).value
      : process.env.PGPORT,
  };

  const pool = new Pool({
    ...poolConfig,
    ssl: isProd,
  });

  const cacheHostName = isProd
    ? (await keyVaultClient.getSecret('AZURE-CACHE-FOR-REDIS-HOST-NAME')).value
    : process.env['AZURE-CACHE-FOR-REDIS-HOST-NAME'];
  const cachePassword = isProd
    ? (await keyVaultClient.getSecret('AZURE-CACHE-FOR-REDIS-ACCESS-KEY')).value
    : process.env['AZURE-CACHE-FOR-REDIS-ACCESS-KEY'];

  if (!cacheHostName || !cachePassword) {
    throw new Error('Missing redis environment variables');
  }

  const cacheConnection = redis.createClient({
    // rediss for TLS
    url: `rediss://${cacheHostName}:6380`,
    password: cachePassword,
  });
  await cacheConnection.connect();
  console.log('Connected to Redis');

  app.post('/calculate', async (req, res) => {
    try {
      const { num1, num2 } = req.body;
      const num1Parsed = Number(num1);
      const num2Parsed = Number(num2);

      if (isNaN(num1Parsed) || isNaN(num2Parsed)) {
        return res.status(400).send('Invalid input');
      }
      const cacheKey = `${num1Parsed}:${num2Parsed}`;
      const cachedResult = await cacheConnection.get(cacheKey);
      // we assume that this process is the limiting factor
      const getResult = async () => {
        if (cachedResult) {
          console.log('cache hit');
          return Number(cachedResult);
        }
        console.log('cache miss');
        const calcRes = num1Parsed + num2Parsed;
        await cacheConnection.set(cacheKey, calcRes);
        return calcRes;
      };
      const result = await getResult();

      const client = await pool.connect();
      try {
        await client.query(
          'INSERT INTO hist_log(num1, num2, result) VALUES($1, $2, $3)',
          [num1Parsed, num2Parsed, result]
        );
      } catch (err) {
        console.error('Error inserting log', err);
        throw err;
      }

      res.send({ result });
      client.release();
    } catch (e) {
      console.error('Error processing /calculate request', e);
      res.status(500).send('Internal Server Error');
    }
  });

  app.get('/hist_log', async (_, res) => {
    try {
      const client = await pool.connect();
      const dbResult = await client.query(
        'SELECT * FROM hist_log ORDER BY created_at DESC LIMIT 5'
      );
      res.send(
        dbResult.rows.map((row) => ({
          num1: Number(row.num1),
          num2: Number(row.num2),
          result: Number(row.result),
        }))
      );
      client.release();
    } catch (e) {
      console.error('Error processing /hist_log request', e);
      res.status(500).send('Internal Server Error');
    }
  });

  app.post('/setup', async (_, res) => {
    try {
      const client = await pool.connect();
      const createTableQuery = `
        CREATE TABLE IF NOT EXISTS hist_log (
          id SERIAL PRIMARY KEY,
          num1 NUMERIC NOT NULL,
          num2 NUMERIC NOT NULL,
          result NUMERIC NOT NULL,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
      `;
      await client.query(createTableQuery);
      res.send('Table created');
      client.release();
    } catch (e) {
      console.error('Error processing /setup request', e);
      res.status(500).send('Internal Server Error');
    }
  });

  app.get('/', async (req, res) => {
    res.send('Hello World from version 4!\n');
  });

  app.get('/test_redis', async (req, res) => {
    try {
      res.send('PING: ' + (await cacheConnection.ping()));
    } catch (e) {
      console.error('Error processing /test_redis request', e);
      res.status(500).send('Internal Server Error');
    }
  });

  app.listen(process.env.PORT, () => {
    console.log(`Server running on port ${process.env.PORT}`);
  });

  process.on('exit', async () => {
    cacheConnection.disconnect();
    await pool.end();
  });
}

main().catch((e) => {
  console.error('Error starting server: ', e);
  process.exit(1);
});
