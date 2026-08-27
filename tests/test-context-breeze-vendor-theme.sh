#!/usr/bin/env bash
# Breeze detection must work when themes are COMPOSER PACKAGES and app/etc/config.php
# carries no `themes` array.
#
# REGRESSION GUARD (CTX-Breeze). Two independent defects made `theme.breeze.active` read
# false on a storefront that was demonstrably running Breeze (the responses carried
# `x-built-with: Breeze Front`):
#
#   1. The frontend theme was resolved ONLY from `app/etc/config.php`'s `themes` array.
#      That key is written by `setup:upgrade` on some installs and absent on others — on a
#      store installed from composer it is routinely missing entirely, and the resolver
#      then reported theme.frontend = null.
#   2. The Breeze parent-chain walk read `app/design/frontend/<Vendor>/<theme>/theme.xml`
#      and nothing else. Themes distributed as composer packages live under
#      `vendor/<vendor>/<pkg>/` and declare their path in registration.php, so the walk
#      found no theme.xml and stopped at the first hop.
#
# Either one alone is enough to mis-report. Because `active` gates every breeze-*
# skill and steers dimension selection in audit, a false negative silently drops
# Breeze coverage from a storefront that needs it — which is worse than refusing outright,
# because nothing signals the gap.
#
# The fixture mirrors a real 2.4.9 install: no `themes` key, and the chain
# Muon/cosmic -> Swissup/breeze-evolution -> Swissup/breeze-blank spread across vendor
# packages, with Magento/blank present so the "prefer a non-Magento theme" rule is exercised.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if ! command -v php >/dev/null 2>&1; then
    echo "skip: php not on PATH"
    exit 77
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "skip: python3 not on PATH"
    exit 77
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -r skills "$WORK/" 2>/dev/null || true

mkdir -p "$WORK/app/etc"

cat > "$WORK/composer.json" <<'EOF'
{
  "require": {
    "magento/product-community-edition": "2.4.9",
    "swissup/breeze-evolution": "^2.31"
  }
}
EOF

# No `themes` key — the case the resolver used to give up on.
cat > "$WORK/app/etc/config.php" <<'EOF'
<?php
return [
    'modules' => [
        'Magento_Store' => 1,
        'Swissup_Breeze' => 1,
    ],
];
EOF

# --- Theme packages, exactly as composer installs them ------------------------
theme_pkg() { # <pkg-dir> <frontend/Vendor/theme> <parent-or-empty> <registration-style>
    local dir="$WORK/vendor/$1" path="$2" parent="$3" style="$4"
    mkdir -p "$dir"

    if [ "$style" = "multiline" ]; then
        cat > "$dir/registration.php" <<EOF
<?php
use Magento\Framework\Component\ComponentRegistrar;

ComponentRegistrar::register(
    ComponentRegistrar::THEME,
    '${path}',
    __DIR__,
);
EOF
    else
        cat > "$dir/registration.php" <<EOF
<?php
use Magento\Framework\Component\ComponentRegistrar;

ComponentRegistrar::register(ComponentRegistrar::THEME, '${path}', __DIR__);
EOF
    fi

    if [ -n "$parent" ]; then
        cat > "$dir/theme.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<theme xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <title>${path}</title>
    <parent>${parent}</parent>
</theme>
EOF
    else
        cat > "$dir/theme.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<theme xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <title>${path}</title>
</theme>
EOF
    fi
}

# Both registration styles appear in the wild; the multi-line form (with a trailing comma)
# is what the real Muon theme ships, and a naive single-line regex misses it.
theme_pkg "muon/theme-frontend-cosmic"            "frontend/Muon/cosmic"              "Swissup/breeze-evolution" multiline
theme_pkg "swissup/theme-frontend-breeze-evolution" "frontend/Swissup/breeze-evolution" "Swissup/breeze-blank"     oneline
theme_pkg "swissup/theme-frontend-breeze-blank"   "frontend/Swissup/breeze-blank"     ""                         oneline
theme_pkg "magento/theme-frontend-blank"          "frontend/Magento/blank"            ""                         oneline

# A test fixture buried deep inside a package must never be mistaken for a real theme.
mkdir -p "$WORK/vendor/magento/module-theme/Test/Unit/Model/_files/frontend/magento_iphone"
cat > "$WORK/vendor/magento/module-theme/Test/Unit/Model/_files/frontend/magento_iphone/theme.xml" <<'EOF'
<?xml version="1.0"?>
<theme><title>Fixture</title><parent>Magento/blank</parent></theme>
EOF

OUT="$(cd "$WORK" && bash skills/context/scripts/resolve-context.sh --no-cache 2>/dev/null || true)"

if [ -z "$OUT" ]; then
    echo "FAIL: resolver produced no output"
    exit 1
fi

python3 - "$OUT" <<'PY'
import sys, json

d = json.loads(sys.argv[1])
theme = d.get("theme") or {}
breeze = theme.get("breeze") or {}

fe = theme.get("frontend")
if fe is None:
    print("FAIL: theme.frontend is null — themes are composer packages here and "
          "app/etc/config.php has no `themes` key, but they are still discoverable "
          "from vendor registration.php")
    sys.exit(1)

if fe != "Muon/cosmic":
    print(f"FAIL: theme.frontend={fe!r} (expected 'Muon/cosmic' — the leaf of the parent "
          f"chain, and the only non-Magento theme nothing else inherits from)")
    sys.exit(1)

if not theme.get("frontend_source"):
    print("FAIL: theme.frontend_source is empty — a resolved value must record where it came from")
    sys.exit(1)

if breeze.get("installed") is not True:
    print(f"FAIL: theme.breeze.installed={breeze.get('installed')!r} (expected True — "
          f"composer requires swissup/breeze-evolution)")
    sys.exit(1)

if breeze.get("active") is not True:
    print(f"FAIL: theme.breeze.active={breeze.get('active')!r} (expected True — "
          f"Muon/cosmic -> Swissup/breeze-evolution)")
    sys.exit(1)

if breeze.get("parent") != "Swissup/breeze-evolution":
    print(f"FAIL: theme.breeze.parent={breeze.get('parent')!r} "
          f"(expected 'Swissup/breeze-evolution')")
    sys.exit(1)

src = breeze.get("source") or ""
if "breeze-evolution" not in src:
    print(f"FAIL: theme.breeze.source={src!r} does not name the resolved Breeze ancestor")
    sys.exit(1)
PY
[ $? -eq 0 ] || exit 1

# --- Honest gap: Breeze installed, storefront running a Luma child ------------
# `swissup/module-breeze` can be present while the storefront runs an ordinary Luma-derived
# theme — the module ships no theme of its own, the Breeze themes are separate packages. Here
# the only non-Magento theme is Acme/storefront and its chain reaches Luma, so there is
# positive evidence AGAINST Breeze and `active` must stay false; otherwise the breeze skills
# would adapt a storefront that never renders Breeze.
#
# Note the case deliberately NOT asserted here: when the sole non-Magento theme registered IS
# a Breeze theme, the resolver infers Breeze. That is the correct reading of the evidence
# available without the DB — a store does not install and register a Breeze theme in order to
# run Luma — and `frontend_source` marks the pick unverified either way.
WORK2="$(mktemp -d)"
trap 'rm -rf "$WORK" "$WORK2"' EXIT
cp -r skills "$WORK2/" 2>/dev/null || true
mkdir -p "$WORK2/app/etc" "$WORK2/vendor/magento/theme-frontend-luma" "$WORK2/vendor/acme/theme-frontend-storefront"

cat > "$WORK2/composer.json" <<'EOF'
{ "require": { "magento/product-community-edition": "2.4.9", "swissup/module-breeze": "^2.31" } }
EOF
cat > "$WORK2/app/etc/config.php" <<'EOF'
<?php
return ['modules' => ['Magento_Store' => 1, 'Swissup_Breeze' => 1]];
EOF
cat > "$WORK2/vendor/magento/theme-frontend-luma/registration.php" <<'EOF'
<?php
use Magento\Framework\Component\ComponentRegistrar;
ComponentRegistrar::register(ComponentRegistrar::THEME, 'frontend/Magento/luma', __DIR__);
EOF
cat > "$WORK2/vendor/magento/theme-frontend-luma/theme.xml" <<'EOF'
<?xml version="1.0"?><theme><title>Luma</title></theme>
EOF
cat > "$WORK2/vendor/acme/theme-frontend-storefront/registration.php" <<'EOF'
<?php
use Magento\Framework\Component\ComponentRegistrar;
ComponentRegistrar::register(ComponentRegistrar::THEME, 'frontend/Acme/storefront', __DIR__);
EOF
cat > "$WORK2/vendor/acme/theme-frontend-storefront/theme.xml" <<'EOF'
<?xml version="1.0"?><theme><title>Acme</title><parent>Magento/luma</parent></theme>
EOF

OUT2="$(cd "$WORK2" && bash skills/context/scripts/resolve-context.sh --no-cache 2>/dev/null || true)"

python3 - "$OUT2" <<'PY'
import sys, json

d = json.loads(sys.argv[1])
theme = d.get("theme") or {}
breeze = theme.get("breeze") or {}

if breeze.get("installed") is not True:
    print(f"FAIL(no-active): installed={breeze.get('installed')!r} (expected True — "
          f"swissup/module-breeze is required)")
    sys.exit(1)

if theme.get("frontend") != "Acme/storefront":
    print(f"FAIL(no-active): theme.frontend={theme.get('frontend')!r} "
          f"(expected 'Acme/storefront')")
    sys.exit(1)

if breeze.get("active") is True:
    print("FAIL(no-active): active=True — the active theme's chain reaches Magento/luma, "
          "so Breeze is installed but not rendering")
    sys.exit(1)

if breeze.get("parent") is not None:
    print(f"FAIL(no-active): parent={breeze.get('parent')!r} (expected null)")
    sys.exit(1)
PY
[ $? -eq 0 ] || exit 1

echo "PASS: breeze detection resolves vendor-packaged themes without a config.php themes array"
