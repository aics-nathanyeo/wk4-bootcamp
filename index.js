import express from 'express';
import pg from 'pg';

const { Pool } = pg;
const app = express();
app.use(express.json());
const pool = new Pool();

app.post('/calculate', async (req, res) => {
  try {
    const { num1, num2 } = req.body;
    const num1Parsed = Number(num1);
    const num2Parsed = Number(num2);

    if (isNaN(num1Parsed) || isNaN(num2Parsed)) {
      return res.status(400).send('Invalid input');
    }

    const result = num1Parsed + num2Parsed;

    const client = await pool.connect();
    try {
      await client.query('INSERT INTO hist_log(num1, num2) VALUES($1, $2)', [
        num1Parsed,
        num2Parsed,
      ]);
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

app.get('/hist_log', async (req, res) => {
  try {
    const client = await pool.connect();
    const dbResult = await client.query(
      'SELECT * FROM hist_log ORDER BY created_at DESC LIMIT 5'
    );
    res.send(
      dbResult.rows.map((row) => ({
        num1: Number(row.num1),
        num2: Number(row.num2),
        result: Number(row.num1) + Number(row.num2),
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
});

app.listen(process.env.PORT, () => {
  console.log(`Server running on port ${process.env.PORT}`);
});

process.on('exit', async () => {
  console.log('test');
  await pool.end();
  console.log('test2');
});
