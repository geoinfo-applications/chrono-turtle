SET search_path TO chronoturtle, public;

CREATE SCHEMA twin;

CREATE TABLE twin.left_side
(
    id   INT PRIMARY KEY,
    name TEXT NOT NULL
);
CREATE TABLE twin.right_side
(
    id   INT PRIMARY KEY,
    name TEXT NOT NULL
);

SELECT migrate_to_vie('twin.left_side', 'twin.right_side');

INSERT INTO twin.left_side (id, name)
VALUES (1, 'same');
INSERT INTO twin.right_side (id, name)
VALUES (1, 'same');

SELECT id, name
FROM twin.left_side;
SELECT id, name
FROM twin.right_side;

DELETE
FROM twin.left_side
WHERE id = 1;
DELETE
FROM twin.right_side
WHERE id = 1;

SELECT id, name
FROM twin.left_side;
SELECT id, name
FROM twin.right_side;
