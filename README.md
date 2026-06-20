# Sample Reports

This directory contains sample report templates for the L-Inspector reporting system.

## Report Structure

Each report is a directory containing the following files:

### Required Files

1. **`metadata.yaml`** - Report configuration and parameters
2. **`index.html.j2`** - Jinja2 HTML template for rendering
3. **`*.sql`** - One or more SQL query files

### File Naming Rules

#### SQL Query Files

- **Naming Convention**: Use descriptive names with underscores (e.g., `table_stats.sql`, `columns.sql`)
- **Parameters**: Use named parameters with colon prefix (e.g., `:schema_name`, `:table_name`)
- **Type Casts**: PostgreSQL type casts (e.g., `::regclass`, `::integer`) are supported and won't be confused with parameters
- **No Positional Parameters**: Do NOT use positional parameters like `$1`, `$2` - always use named parameters

**Example SQL file:**
```sql
-- Good: Named parameters
SELECT * FROM pg_tables 
WHERE schemaname = COALESCE(:schema_name, 'public')
  AND tablename = :table_name;

-- Good: Type cast is preserved
SELECT (:schema_name || '.' || :table_name)::regclass;

-- Bad: Positional parameters are not allowed
SELECT * FROM pg_tables WHERE schemaname = $1;
```

#### Template Files

- **Name**: Must be `index.html.j2`
- **Format**: Jinja2 template with HTML

### Template Context

Templates receive the following context variables:

#### `globals` - Report Metadata
- `globals.template_name` - Report ID (directory name)
- `globals.report_name` - Human-readable report name from metadata
- `globals.generated_at` - ISO timestamp when report was generated
- `globals.version` - Report version from metadata

#### `params` - User Parameters
- Dictionary of user-provided parameter values
- Access via `params.parameter_name`
- Example: `{{ params.schema_name }}`, `{{ params.table_name }}`

#### `queries` - Query Results
- Dictionary where keys are SQL filenames (without `.sql` extension)
- Values are lists of row dictionaries
- Each row is a dictionary with column names as keys

**Example:**
```jinja2
{# Access query results from tables_list.sql #}
{% for row in queries.tables_list %}
  <tr>
    <td>{{ row.schema_name }}</td>
    <td>{{ row.table_name }}</td>
    <td>{{ row.total_size }}</td>
  </tr>
{% endfor %}

{# Check if query returned results #}
{% if queries.columns %}
  <h2>Columns ({{ queries.columns | length }})</h2>
{% endif %}
```

### Available Jinja2 Filters

- `format_number` - Format numbers with thousand separators: `{{ value | format_number }}`
- `format_date` - Format dates as YYYY-MM-DD: `{{ date | format_date }}`
- `format_datetime` - Format datetime as YYYY-MM-DD HH:MM:SS: `{{ datetime | format_datetime }}`
- `image_url` - Generate S3 presigned URL for remote images: `{{ 'path/to/image.jpg' | image_url }}`
- `local_image` - Embed local images as base64 data URIs: `{{ 'logo.png' | local_image }}`

### Using Local Images

You can embed images stored in the same directory as your template using the `local_image` filter. This is useful for logos, icons, or any static images that should be included in the report.

**Supported formats:** `.png`, `.jpg`, `.jpeg`, `.gif`, `.svg`, `.webp`, `.bmp`

**Example usage:**
```jinja2
{# Simple image embedding #}
<img src="{{ 'logo.png' | local_image }}" alt="Company Logo">

{# Conditional image display #}
{% if 'header.jpg' | local_image %}
    <img src="{{ 'header.jpg' | local_image }}" alt="Header">
{% else %}
    <p>Header image not found</p>
{% endif %}

{# Dynamic image from query results #}
{% for item in queries.data %}
    {% if item.image_filename %}
        <img src="{{ item.image_filename | local_image }}" alt="{{ item.name }}">
    {% endif %}
{% endfor %}
```

**Example:** Place a file named `logo.png` in your report directory (e.g., `sample_reports/inspection-rep/logo.png`), then use it in your template with `{{ 'logo.png' | local_image }}`.

### Metadata File Format

```yaml
name: "Report Display Name"
description: "Optional description of what this report does"
version: "1.0"
timeout: 120  # Query timeout in seconds (optional)
cache_ttl_minutes: 10  # Cache TTL in minutes (optional, overrides global default of 5 minutes)

parameters:
  - name: schema_name
    type: string
    required: false
    description: "Database schema name"
    default: "public"
  
  - name: table_name
    type: string
    required: true
    description: "Table name to analyze"
```

#### Metadata Properties
- `name` - Human-readable report name (required)
- `description` - Detailed description of the report (optional)
- `version` - Report version string (default: "1.0")
- `timeout` - Maximum query execution time in seconds (optional)
- `cache_ttl_minutes` - Cache time-to-live in minutes for this specific report (optional).
  If not specified, uses the global default (5 minutes). Set higher for reports with
  slowly-changing data, lower for real-time reports.
- `parameters` - List of parameter definitions (optional)

#### Parameter Types
- `string` - Text value
- `integer` - Whole number
- `float` - Decimal number
- `boolean` - True/False
- `date` - Date in ISO format (YYYY-MM-DD)
- `datetime` - Date and time in ISO format

#### Parameter Properties
- `name` - Parameter identifier (required)
- `type` - Data type (required)
- `required` - Whether parameter must be provided (default: false)
- `description` - Human-readable description (optional)
- `default` - Default value if not provided (optional)
- `enum` - List of allowed values (optional)

### Important Notes

1. **Parameters in Queries**: Not all parameters need to be used in every SQL query. Each query only binds the parameters it actually references.

2. **Reports Without Parameters**: Reports can have no parameters at all - just omit the `parameters` section in metadata.yaml or use an empty list.

3. **Query Results**: Query results are converted to lists of dictionaries. Access columns using dot notation or bracket notation in templates.

4. **Type Casts**: PostgreSQL type casts like `::regclass`, `::integer`, `::text` are properly handled and won't be mistaken for parameters.

## Example Reports

### database-tables
Lists all tables in a schema with size information.
- Parameters: `schema_name` (optional, default: "public")
- Queries: `tables_list.sql`, `table_stats.sql`

### table-details
Detailed information about a specific table including columns, indexes, and constraints.
- Parameters: `schema_name` (optional), `table_name` (required)
- Queries: `table_info.sql`, `columns.sql`, `indexes.sql`, `constraints.sql`, `row_stats.sql`

### simple-test
Minimal example with no parameters.
- Parameters: None
- Queries: `data.sql`

## Creating a New Report

1. Create a new directory in `sample_reports/`
2. Add `metadata.yaml` with report configuration
3. Create SQL query files with named parameters
4. Create `index.html.j2` template using the context variables
5. Test the report through the UI

## Best Practices

- Use descriptive names for SQL files that indicate what data they fetch
- Keep SQL queries focused - one query per logical data set
- Use consistent styling in templates (see existing reports for examples)
- Add comments in SQL files to explain complex queries
- Test with various parameter combinations
- Handle empty query results gracefully in templates using `{% if queries.query_name %}`
