\connect tracker_dev
ALTER EXTENSION "citext" UPDATE;
ALTER EXTENSION "btree_gist" UPDATE;
\connect tracker_test
ALTER EXTENSION "citext" UPDATE;
ALTER EXTENSION "btree_gist" UPDATE;
