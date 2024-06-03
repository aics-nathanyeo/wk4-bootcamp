import express from 'express';
import pg from 'pg';
import redis from 'redis';

const { Pool } = pg;
const app = express();
app.use(express.json());
const pool = new Pool();
const cacheHostName = process.env.AZURE_CACHE_FOR_REDIS_HOST_NAME;
const cachePassword = process.env.AZURE_CACHE_FOR_REDIS_ACCESS_KEY;
if (!cacheHostName || !cachePassword) {
  console.error('Missing redis environment variables');
  process.exit(1);
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

app.get('/', async (req, res) => {
  res.send('Hello World!\n');
  console.log('cache response' + (await cacheConnection.ping()));
});

app.listen(process.env.PORT, () => {
  console.log(`Server running on port ${process.env.PORT}`);
});

process.on('exit', async () => {
  cacheConnection.disconnect();
  await pool.end();
});
