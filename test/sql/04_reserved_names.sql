SET search_path TO chronoturtle, public;
\set VERBOSITY terse

CREATE SCHEMA reserved;

CREATE TABLE reserved."user"
(
    id   SERIAL PRIMARY KEY,
    name TEXT NOT NULL
);
CREATE TABLE reserved."order"
(
    id      SERIAL PRIMARY KEY,
    user_id INT NOT NULL REFERENCES reserved."user" (id),
    note    TEXT
);

INSERT INTO reserved."user" (name)
VALUES ('alice');
INSERT INTO reserved."order" (user_id, note)
VALUES (1, 'first order');

SELECT migrate_to_vie('reserved.user', 'reserved.order');

UPDATE reserved."user"
SET name = 'alice renamed'
WHERE id = 1;
INSERT INTO reserved."user" (name)
VALUES ('bob');
INSERT INTO reserved."order" (user_id, note)
VALUES (2, 'second order');
DELETE
FROM reserved."order"
WHERE id = 1;

SELECT id, name
FROM reserved."user"
ORDER BY id;
SELECT id, user_id, note
FROM reserved."order"
ORDER BY id;

SELECT set_current_branch('feature/reserved');
INSERT INTO reserved."user" (name)
VALUES ('carol');
SELECT set_current_branch('main');
SELECT id, name
FROM reserved."user"
ORDER BY id;

SELECT add_unique_constraint('reserved.user', 'name');
INSERT INTO reserved."user" (name)
VALUES ('bob');
SELECT drop_unique_constraint('reserved.user', 'name_key');
INSERT INTO reserved."user" (name)
VALUES ('bob');

SELECT drop_vie_table('reserved.order', true);
SELECT drop_vie_table('reserved.user');

SELECT id, name
FROM reserved."user"
ORDER BY id, name;
