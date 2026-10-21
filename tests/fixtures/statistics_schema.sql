PRAGMA user_version = 20221111;

CREATE TABLE book (
    id INTEGER PRIMARY KEY,
    authors TEXT
);

CREATE TABLE page_stat_data (
    id_book INTEGER NOT NULL,
    page INTEGER NOT NULL,
    start_time INTEGER NOT NULL,
    duration INTEGER NOT NULL,
    total_pages INTEGER NOT NULL
);

INSERT INTO book (id, authors) VALUES
    (1, 'Ada Lovelace'),
    (2, 'Lovelace, Ada');

INSERT INTO page_stat_data (id_book, page, start_time, duration, total_pages) VALUES
    (1, 1, 1500, 60, 100),
    (2, 1, 1600, 90, 120);
