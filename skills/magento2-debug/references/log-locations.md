# Log Locations

Canonical reference for Magento 2 log paths and how to read them. Shared by
`magento2-debug` and `magento2-bug-fix` (bug-fix's `log-targets.md` points here). Resolve
relative paths against `{ctx.magento_root}`.

## Magento Core

| Path                         | Contents                                      |
|------------------------------|-----------------------------------------------|
| `var/log/system.log`         | Every PSR-3 record **without** an exception in its context, at INFO and above — including `->error()` / `->critical()` calls that pass a plain string |
| `var/log/exception.log`      | Only records that carry `context['exception']` — see the routing note below |
| `var/log/debug.log`          | All levels when `developer/debug/debug_logging = 1` |
| `var/log/cron.log`           | Cron worker activity                          |
| `var/log/payment.log`        | Payment integrations when payment debug is on |
| `var/log/support_report.log` | Adobe Commerce support tool output            |
| `var/report/{sha256}`        | Uncaught web-request exception, written by `pub/errors/processor.php::saveReport()` via `Magento\Framework\App\ExceptionHandler`. Nested as `var/report/xx/yy/{sha256}` when `MAGE_ERROR_REPORT_DIR_NESTING_LEVEL` (env) or `dir_nesting_level` in `pub/errors/local.xml` is set — **scan recursively** |
| `var/report/api/{id}`        | PHP **fatal** during a REST/GraphQL request, written by `Magento\Framework\Webapi\ErrorProcessor::apiShutdownFunction()` |

(There is no standard `var/log/connection.log` in core Magento — a module may create one,
but don't assume it exists.)

### Which sink gets the record — and what that means for "nothing in the log"

`Magento\Framework\Logger\Handler\System::write()` sends a record to `exception.log` **only
when `$record['context']['exception']` is set**; everything else at INFO+ goes to `system.log`.
Severity is irrelevant to that routing. Two consequences worth remembering when a user reports
"an error with nothing in exception.log":

- `$logger->critical('Some message')` — a string, no exception object — lands in `system.log`.
  The canonical example is `Magento\Framework\ObjectManager\Factory\AbstractFactory`, which
  logs `Type Error occurred when creating object: Vendor\Module\Plugin\Foo, Too few arguments`
  as a string critical when a plugin's constructor signature does not match its DI wiring.
- `var/report/api/{id}` is written with **no logger call at all**, so a REST/GraphQL fatal
  (memory exhaustion, parse error, uncaught `TypeError` in the shutdown path) leaves a report
  file and nothing else.

So when triaging, read `var/report/` and `system.log` before concluding an error went unlogged.
Report files are JSON on 2.4.x (`{"0": message, "1": trace, "url": …, "report_id": …}`) and
PHP-`serialize()`d on older versions:

```
{ctx.runner} find var/report -type f -newermt '-1 hour'      # recent reports, any nesting
{ctx.runner} php -r 'print_r(json_decode(file_get_contents("var/report/{id}"), true));'
```

The `report_id` in a `var/report/{sha256}` file is also logged with the `exception.log` entry on
2.4.7+ (`ExceptionHandler.php:252`), which is what lets you join the two. `var/report/api/*` ids
have no such counterpart.

## Custom Module

Modules registering Monolog stream handlers typically write to:

- `var/log/{vendor}_{module}.log`
- `var/log/{module}.log`

Find the exact path via `grep -rE 'StreamHandler' {ctx.magento_root}/app/code/{Vendor}/{Module}/`
(look for the file path passed to `new StreamHandler(...)` in DI or the logger virtualType).

## Container / Infrastructure

| Path                                | Contents                                                  |
|-------------------------------------|-----------------------------------------------------------|
| `/var/log/nginx/error.log` (host)   | Reverse-proxy errors, 502s, upstream timeouts             |
| `/var/log/php-fpm/error.log` (host) | PHP-FPM worker errors                                     |
| `docker compose logs php`           | Container stdout — captures everything if not redirected  |
| `docker compose logs mysql`         | DB errors (deadlocks, slow queries when slow log enabled) |
| `docker compose logs rabbitmq`      | Queue consumer errors                                     |
| `docker compose logs redis`         | Cache layer errors                                        |

## Reading via Runner

Prepend `{ctx.runner}` when the logs live inside a container:

```
{ctx.runner} tail -n 200 var/log/exception.log
{ctx.runner} grep -E "MyVendor_MyModule" var/log/system.log
```

## Time Windows

Grep with `--since` when the tool supports it; otherwise use `tail -n` heuristics:

| Recency      | Approach                                  |
|--------------|-------------------------------------------|
| Last minute  | `tail -n 200 var/log/exception.log`       |
| Last hour    | `tail -n 5000` or `awk '$1 >= "{HH:MM}"'` |
| Last day     | full file scan, group by signature        |
| Since deploy | `awk '$1 " " $2 >= "{deploy_timestamp}"'` |

## Grep Patterns by Symptom

| Symptom                  | Pattern                                                                        |
|--------------------------|--------------------------------------------------------------------------------|
| 500 error / white screen | `grep -E "Fatal\|Exception\|TypeError" var/log/exception.log`; then `find var/report -type f -newermt '-1 hour'` |
| Error with nothing in exception.log | `grep -E "\.(CRITICAL\|ERROR):" var/log/system.log` + `find var/report -type f -newermt '-1 hour'` |
| Plugin/DI wiring broken | `grep "Type Error occurred when creating object" var/log/system.log` |
| REST/GraphQL 500 with empty logs | `find var/report/api -type f -newermt '-1 hour'` |
| Slow page                | `grep -E "took [0-9]{4,}ms" var/log/system.log` (if a profiler logs durations) |
| Queue stuck              | `grep -E "consumer\|queue\|amqp" var/log/system.log`                           |
| Cron not running         | `grep -E "cron\|crontab" var/log/cron.log`                                     |
| Cache mishit             | `grep -E "cache\|getKey\|getIdentities" var/log/debug.log`                     |
| Payment failure          | `grep -E "gateway\|capture\|authorize" var/log/payment.log`                    |

## What to Search When the Symptom Is "No Log Entry"

Order matters — cheapest and most often decisive first:

1. `var/report/` (recursive, mtime-filtered) — a file there means a request died.
2. `var/log/system.log` at CRITICAL/ERROR — string-level criticals live only here.
3. Module channels: `ls -t var/log/*.log | head` — a third-party logger may own the failure.
4. `var/log/exception.log` — only then, and note that an empty diff here is not "no error".

## Log Rotation

If a log appears empty, look for `*.log.1` or `*.gz` siblings before concluding "no
entries". Magento does **not** rotate its own logs by default; OS-level logrotate may have
moved recent entries. (There is no `dev:di:info`-style log-truncation job — that command
reports DI info and has nothing to do with logs.)

## What to Save

For each log file searched, record (in the consuming skill's collect/snapshot artefact —
e.g. bug-fix saves to `.docs/bug-fixes/{slug}/collect.md`):

- Path searched
- Pattern used
- Match count
- 3–5 sample matches with timestamps

Do not paste raw log dumps into the conversation — group by error signature and surface the
top distinct entries.
