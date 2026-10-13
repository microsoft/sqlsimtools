# SQL Example Files

T-SQL scripts for `sqlpysim -i`. Batches are separated by `GO`, and each batch
is timed separately.

| File | What it runs | Database |
| --- | --- | --- |
| `01-simple-queries.sql` | Catalog view queries that verify connectivity | Any |
| `02-customer-queries-adventureworkslt.sql` | Customer lookups with filters | AdventureWorksLT |
| `03-product-queries-adventureworkslt.sql` | Product catalog queries | AdventureWorksLT |
| `04-sales-queries-adventureworkslt.sql` | Sales orders with joins | AdventureWorksLT |
| `05-aggregation-queries-adventureworkslt.sql` | Aggregation and `GROUP BY` | AdventureWorksLT |
| `06-complex-joins-adventureworkslt.sql` | Multi-table joins | AdventureWorksLT |
| `07-insert-test-adventureworkslt.sql` | `INSERT` into a temporary table that it cleans up | AdventureWorksLT |
| `08-mixed-workload-adventureworkslt.sql` | Mixed OLTP-style reads for multi-threaded load tests | AdventureWorksLT |
| `09-reporting-queries-adventureworkslt.sql` | Analytical reporting queries | AdventureWorksLT |
| `setup-managed-identity-access.sql` | Grants a managed identity access to Azure SQL Database; run it yourself as the Microsoft Entra admin | Azure SQL Database |

All files except `07-insert-test-adventureworkslt.sql` and
`setup-managed-identity-access.sql` are read-only.

## Run a file

From the `sqlpysim` folder:

```powershell
# Any database
python sqlpysim.py -S localhost -E -C -i examples\sql\01-simple-queries.sql

# AdventureWorksLT, 10 threads x 100 iterations, quiet
python sqlpysim.py -S localhost -d AdventureWorksLT -E -C -i examples\sql\08-mixed-workload-adventureworkslt.sql -n 10 -r 100 -q
```

The scripts in [../powershell/](../powershell/README.md) run these files for you.