-- One row per trial start. No IP addresses, user agents or other request data.
CREATE TABLE trials (
  app TEXT NOT NULL,
  env TEXT NOT NULL CHECK (env IN ('live', 'test')),
  device TEXT NOT NULL,
  started_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (app, env, device)
) WITHOUT ROWID;
