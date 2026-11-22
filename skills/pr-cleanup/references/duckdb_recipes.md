# Ad-Hoc Sorting & Filtering with DuckDB (`--json`)

When the user asks for custom sorting, age calculations, or filtering (for
example, oldest open PRs by `createdAt`, stalest `updatedAt`, or specific
reviewer/CI states), pipe `--json` into `duckdb -markdown` instead of adding new
CLI flags:

```bash
# Project & sort active GitHub PRs + Gerrit CLs (active) by opened/touched date:
kscripts pr-cleanup --json | duckdb -markdown -c "
  WITH a AS (
    SELECT unnest(active, recursive := true)
    FROM read_json_auto('/dev/stdin')
  )
  SELECT
    '[' || CASE WHEN source='github' THEN '#' ELSE 'CL ' END || number || '](' || url || ')' AS Target,
    repository AS Repo,
    left(title, 42) AS Title,
    ciBadge AS CI,
    reviewBadge AS Review,
    strftime(createdAt::TIMESTAMPTZ, '%Y-%m-%d') AS Opened,
    strftime(updatedAt::TIMESTAMPTZ, '%Y-%m-%d') AS Touched,
    date_diff('day', createdAt::TIMESTAMPTZ, now()) AS AgeDays
  FROM a
  ORDER BY createdAt ASC;
"

# Project & filter rich open GitHub PR telemetry from gh-view --json:
kscripts gh-view --json | duckdb -markdown -c "
  WITH prs AS (
    SELECT unnest(items, recursive := true)
    FROM read_json_auto('/dev/stdin')
  )
  SELECT
    '[#' || number || '](' || url || ')' AS PR,
    repository AS Repo,
    category AS Bucket,
    ciStatus AS CI,
    strftime(createdAt::TIMESTAMPTZ, '%Y-%m-%d') AS Opened,
    touched AS Touched
  FROM prs
  WHERE NOT isDraft
  ORDER BY updatedAt ASC;
"
```
