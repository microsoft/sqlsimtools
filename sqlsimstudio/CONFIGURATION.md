# sqlsim Studio Configuration Files

sqlsim Studio can save the current Configure view to a local JSON file and load
it again later. Configuration files are portable between supported Studio
platforms when the selected execution engine and workload mode are available on
the destination platform.

The current format identifier is `sqlsimstudio.configuration`, version `1`.
Future incompatible formats will use a different version number. Studio rejects
unknown schema identifiers and versions rather than guessing how to interpret
them.

## Security and Storage

- **Save configuration** downloads a `.json` file through the browser. Studio
  does not maintain a hidden server-side copy.
- Passwords, access tokens, client secrets, and other authentication secrets are
  never written to the file.
- `connection.username` may contain a SQL login name or service-principal client
  ID. Loading a configuration always clears Studio's secret field.
- Query text, SQL file contents, workload scripts, replay XML, server names, and
  database names are stored as plain text. Protect the file accordingly.
- A loaded file may contain executable SQL. Review configurations from untrusted
  sources before running them.

## Top-Level Format

```json
{
  "schema": "sqlsimstudio.configuration",
  "version": 1,
  "savedAt": "2026-09-20T18:30:00.000Z",
  "configuration": {
    "engine": "sqlsim",
    "mode": "query",
    "connection": {},
    "source": {},
    "execution": {}
  }
}
```

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `schema` | string | Yes | Must be `sqlsimstudio.configuration`. |
| `version` | integer | Yes | Must be `1`. |
| `savedAt` | ISO 8601 string | Written by Studio | UTC time when Studio saved the file. It is informational. |
| `configuration.engine` | string | Yes | `sqlsim` or `sqlpysim`. |
| `configuration.mode` | string | Yes | `query`, `file`, `workload`, or `replay`. |
| `configuration.connection` | object | Yes | Target and non-secret authentication settings. |
| `configuration.source` | object | Yes | Mode-specific query, script, workload, or replay data. |
| `configuration.execution` | object | Yes | Output and error-handling settings. |

`sqlpysim` supports only `query` and `file` configurations. It does not support
`live` telemetry or `runtime` statistics in Studio.

## Connection Object

```json
{
  "server": "localhost",
  "database": "tempdb",
  "authentication": "integrated",
  "username": null,
  "trustServerCertificate": false
}
```

| Field | Type | Allowed values or limit |
| --- | --- | --- |
| `server` | string | Up to 2,048 characters. |
| `database` | string | Up to 256 characters. |
| `authentication` | string | `integrated`, `token`, `interactive`, `managed`, `service-principal`, or `sql`. |
| `username` | string or null | Up to 1,024 characters. Used for SQL authentication or a service-principal client ID. |
| `trustServerCertificate` | Boolean | `true` or `false`. |

There is intentionally no password, token, or secret property.

## Execution Object

```json
{
  "telemetry": "final",
  "quiet": true,
  "stopOnError": false,
  "statisticsSource": "none"
}
```

| Field | Type | Allowed values |
| --- | --- | --- |
| `telemetry` | string | `live`, `final`, or `console`. |
| `quiet` | Boolean | `true` suppresses result rows. Must be `true` for `live` and `final` structured telemetry. |
| `stopOnError` | Boolean | `true` stops the workload after its first execution error. |
| `statisticsSource` | string | `none`, `runtime`, or `query-store`. |

## Query Source

Use with `configuration.mode` set to `query`.

```json
{
  "query": "SELECT @@VERSION;",
  "threads": 10,
  "iterations": 100
}
```

`query` is limited to 1,000,000 characters. `threads` must be from 1 through
1,000,000, and `iterations` must be from 1 through 1,000,000,000.

## SQL File Source

Use with `configuration.mode` set to `file`.

```json
{
  "fileName": "workload.sql",
  "content": "SELECT 1;\nGO\nSELECT 2;",
  "threads": 10,
  "iterations": 100
}
```

`fileName` is limited to 260 characters and `content` to 1,000,000 characters.
Both may be `null` when no file was selected, but they must be null together.
Thread and iteration limits are the same as Query mode. Studio embeds the SQL
text so loading the configuration does not require the original file.

## Mixed Workload Source

Use with `configuration.mode` set to `workload`. A configuration may contain at
most 20 groups.

```json
{
  "groups": [
    {
      "fileName": "read.sql",
      "content": "SELECT TOP (10) * FROM dbo.Orders;",
      "threads": 8,
      "iterations": 1000,
      "thinkTimeMs": 0
    },
    {
      "fileName": "write.sql",
      "content": "EXEC dbo.ProcessNextOrder;",
      "threads": 2,
      "iterations": 100,
      "thinkTimeMs": 25
    }
  ]
}
```

Each `fileName` is limited to 260 characters and each `content` value to
1,000,000 characters. `threads` and `iterations` use the Query-mode limits.
`thinkTimeMs` must be from 0 through 86,400,000. Studio embeds every SQL script.

## Replay Source

Use with `configuration.mode` set to `replay`. Replay requires the native
`sqlsim` engine.

```json
{
  "fileName": "capture.xml",
  "content": "<Events><Event id=\"1\" /></Events>",
  "replayMode": "stress",
  "iterations": 5,
  "threads": 16
}
```

`fileName` is limited to 260 characters and `content` to 100,000,000
characters. Both may be `null` when no replay was selected, but they must be
null together. `replayMode` is `fast` or `stress`. `iterations` and `threads`
use the Query-mode numeric limits; `threads` is applied only to stress replay.
Studio embeds the replay XML.

## Complete Query Example

```json
{
  "schema": "sqlsimstudio.configuration",
  "version": 1,
  "savedAt": "2026-09-20T18:30:00.000Z",
  "configuration": {
    "engine": "sqlsim",
    "mode": "query",
    "connection": {
      "server": "localhost",
      "database": "tempdb",
      "authentication": "integrated",
      "username": null,
      "trustServerCertificate": false
    },
    "source": {
      "query": "SELECT @@VERSION;",
      "threads": 10,
      "iterations": 100
    },
    "execution": {
      "telemetry": "final",
      "quiet": true,
      "stopOnError": false,
      "statisticsSource": "none"
    }
  }
}
```

Studio accepts configuration files up to 125 MB. It validates the schema,
version, supported combinations, enumerated values, numeric ranges, and text
limits before changing the Configure view. Malformed or unsupported files show
an error and are not applied.
