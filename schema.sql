-- The board's schema, applied by `slate scripts/migrate.sl`.
--
-- Every statement is `if not exists`, so applying it to a database that already has it is a no-op
-- and there is one file to read rather than a chain of numbered ones. A board that grows a column
-- later adds an `alter table ... add column if not exists` at the bottom of this file; what a
-- deployment needs from a schema is that running it twice does what running it once did.

create table if not exists users (
    id       serial primary key,
    name     text not null unique,
    -- An Argon2id PHC record, written by `slate:password`'s `hash` on the thread pool. It carries
    -- its own parameters, so raising them invalidates nothing already stored.
    password text not null,
    role     text not null default 'member',
    -- A photo's name under `uploads/`, which is the base64url of its own SHA-256 and then
    -- what kind of picture it is -- or nothing, for somebody who has not put one up.
    avatar   text,
    made     timestamptz not null default now()
);

create table if not exists threads (
    id       serial primary key,
    title    text not null,
    body     text not null,
    author   integer not null references users (id) on delete cascade,
    photo    text,
    made     timestamptz not null default now(),
    -- Denormalised so that the list can be ordered by either without a join to a count. A board
    -- reads its front page far more often than it is posted to.
    replies  integer not null default 0,
    active   timestamptz not null default now()
);

create table if not exists tags (
    thread integer not null references threads (id) on delete cascade,
    tag    text not null,
    primary key (thread, tag)
);

create table if not exists replies (
    id     serial primary key,
    thread integer not null references threads (id) on delete cascade,
    body   text not null,
    author integer not null references users (id) on delete cascade,
    photo  text,
    made   timestamptz not null default now()
);

-- The three orders the list offers, and the tag filter.
create index if not exists threads_made on threads (made desc);
create index if not exists threads_active on threads (active desc);
create index if not exists threads_replies on threads (replies desc, made desc);
create index if not exists tags_tag on tags (tag);
create index if not exists replies_thread on replies (thread, id);
