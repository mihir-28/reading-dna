import sqlite3
import unittest
from pathlib import Path


QUERY = """
SELECT p.id_book, p.start_time, p.duration, COALESCE(b.authors, ''),
       (SELECT MIN(start_time) FROM page_stat_data WHERE duration > 0)
FROM page_stat_data AS p
LEFT JOIN book AS b ON b.id = p.id_book
WHERE p.start_time >= ? AND p.start_time <= ? AND p.duration > 0
ORDER BY p.start_time ASC
"""


class StatisticsFixtureTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        fixture = Path(__file__).parent / "fixtures/statistics_schema.sql"
        self.db.executescript(fixture.read_text(encoding="utf-8"))

    def tearDown(self):
        self.db.close()

    def test_module_query_reads_events_and_first_history_timestamp(self):
        rows = self.db.execute(QUERY, (1400, 1700)).fetchall()
        self.assertEqual(rows, [
            (1, 1500, 60, "Ada Lovelace", 1500),
            (2, 1600, 90, "Lovelace, Ada", 1500),
        ])

    def test_missing_statistics_table_fails_cleanly_at_query_boundary(self):
        db = sqlite3.connect(":memory:")
        with self.assertRaises(sqlite3.OperationalError):
            db.execute(QUERY, (0, 2000)).fetchall()
        db.close()


if __name__ == "__main__":
    unittest.main()
