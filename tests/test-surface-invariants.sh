#!/usr/bin/env bash
# test-surface-invariants.sh — contract for the surface-completeness rule pack.
#
# Every rule here was derived from a defect observed in production work, where a generator
# emitted an incomplete multi-file surface and every existing gate (XSD, DI compile, PHPUnit,
# phpcs, phpstan) passed. The pack's whole value is precision: a rule that
# fires on correct code is worse than no rule, so the clean fixture asserting ZERO findings is
# as load-bearing as the dirty one.
#
# Rule ids (emitted as the finding's `subcategory`) and the defect class each came from:
#   SI-01 queue-topic-no-publisher            generated queue surface, publisher file omitted
#   SI-02 queue-topic-no-topology-binding     same surface, adjacent gap
#   SI-03 queue-consumer-queue-unbound        same surface, adjacent gap
#   SI-04 cache-type-unregistered             generated cache class, never registered
#   SI-05 cache-injected-as-app-cache         cache type injected under the wrong interface
#   SI-06 grid-collection-not-searchresult    generated grid bound to a vanilla collection
#   SI-07 form-missing-template-item          generated admin form, missing template item
#   SI-08 dynamicrows-datascope-duplicates-name  hand-written dynamicRows double-binding
#   SI-09 acl-foreign-parent-mismatch         generated acl.xml, wrong parent chain (admin lockout)
#   SI-10 collections-registered-in-area-di   grid registration in an area di.xml
#   SI-11 route-action-unresolvable           template route string vs controller class name
#   SI-12 acl-parent-declared-by-no-module    unverified ACL parent path in a blueprint
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if ! command -v python3 >/dev/null 2>&1; then
    echo "skip: python3 not on PATH"
    exit 77
fi

CHECKER="$PWD/skills/magento2-static-analysis/scripts/surface-invariants.sh"
[ -x "$CHECKER" ] || { echo "FAIL: $CHECKER not executable"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAIL=0
fail() { echo "FAIL: $*"; FAIL=1; }

# ---------------------------------------------------------------------------
# Reference set: a stand-in vendor tree so ACL parent chains can be resolved.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/vendor/magento/module-backend/etc" "$WORK/vendor/magento/module-config/etc"
cat > "$WORK/vendor/magento/module-backend/etc/acl.xml" <<'EOF'
<?xml version="1.0"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:framework:Acl/etc/acl.xsd">
  <acl>
    <resources>
      <resource id="Magento_Backend::admin">
        <resource id="Magento_Backend::stores" title="Stores" sortOrder="80">
          <resource id="Magento_Backend::stores_settings" title="Settings" sortOrder="20"/>
        </resource>
      </resource>
    </resources>
  </acl>
</config>
EOF
cat > "$WORK/vendor/magento/module-backend/etc/module.xml" <<'EOF'
<?xml version="1.0"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:framework:Module/etc/module.xsd">
  <module name="Magento_Backend"/>
</config>
EOF
cat > "$WORK/vendor/magento/module-config/etc/module.xml" <<'EOF'
<?xml version="1.0"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:framework:Module/etc/module.xsd">
  <module name="Magento_Config"/>
</config>
EOF
cat > "$WORK/vendor/magento/module-config/etc/acl.xml" <<'EOF'
<?xml version="1.0"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:framework:Acl/etc/acl.xsd">
  <acl>
    <resources>
      <resource id="Magento_Backend::admin">
        <resource id="Magento_Backend::stores">
          <resource id="Magento_Backend::stores_settings">
            <resource id="Magento_Config::config" title="Configuration" sortOrder="20"/>
          </resource>
        </resource>
      </resource>
    </resources>
  </acl>
</config>
EOF

# ---------------------------------------------------------------------------
# DIRTY fixture — one violation per rule.
# ---------------------------------------------------------------------------
D="$WORK/app/code/Acme/Dirty"
mkdir -p "$D/etc/adminhtml" "$D/etc/frontend" "$D/Model/ResourceModel/Widget" \
         "$D/Model/Cache" "$D/Controller/Login" "$D/view/adminhtml/ui_component" \
         "$D/view/frontend/templates/login" "$D/Service"

cat > "$D/etc/module.xml" <<'EOF'
<?xml version="1.0"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:framework:Module/etc/module.xsd">
  <module name="Acme_Dirty"/>
</config>
EOF

# SI-01/02/03 — a topic with no publisher, no topology binding, and a consumer on an unbound queue.
cat > "$D/etc/communication.xml" <<'EOF'
<?xml version="1.0"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:framework:Communication/etc/communication.xsd">
  <topic name="acme.dirty.export" request="Acme\Dirty\Api\Data\ExportInterface">
    <handler name="default" type="Acme\Dirty\Model\ExportHandler" method="process"/>
  </topic>
</config>
EOF
cat > "$D/etc/queue_consumer.xml" <<'EOF'
<?xml version="1.0"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:framework:Communication/etc/consumer.xsd">
  <consumer name="acme.dirty.export" queue="acme.dirty.export.queue" connection="db" handler="Acme\Dirty\Model\ExportHandler::process"/>
</config>
EOF

# SI-04 — cache type class with no cache.xml entry.
cat > "$D/Model/Cache/ExportCache.php" <<'EOF'
<?php
declare(strict_types=1);
namespace Acme\Dirty\Model\Cache;

use Magento\Framework\Cache\Frontend\Decorator\TagScope;
use Magento\Framework\App\Cache\Type\FrontendPool;

class ExportCache extends TagScope
{
    public const TYPE_IDENTIFIER = 'acme_dirty_export';
    public const CACHE_TAG = 'ACME_DIRTY_EXPORT';

    public function __construct(FrontendPool $currentFrontendPool)
    {
        parent::__construct($currentFrontendPool->get(self::TYPE_IDENTIFIER), self::CACHE_TAG);
    }
}
EOF

# SI-05 — that cache type wired into a service typed as App\CacheInterface.
cat > "$D/Service/Exporter.php" <<'EOF'
<?php
declare(strict_types=1);
namespace Acme\Dirty\Service;

use Magento\Framework\App\CacheInterface;

class Exporter
{
    private $cache;

    public function __construct(CacheInterface $cache)
    {
        $this->cache = $cache;
    }
}
EOF

# SI-06 — grid collection registered but it is a plain entity collection.
# SI-10 — that registration lives in the adminhtml-area di.xml instead of etc/di.xml.
cat > "$D/etc/adminhtml/di.xml" <<'EOF'
<?xml version="1.0"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:framework:ObjectManager/etc/config.xsd">
  <type name="Magento\Framework\View\Element\UiComponent\DataProvider\CollectionFactory">
    <arguments>
      <argument name="collections" xsi:type="array">
        <item name="acme_dirty_widget_listing_data_source" xsi:type="string">Acme\Dirty\Model\ResourceModel\Widget\Collection</item>
      </argument>
    </arguments>
  </type>
  <type name="Acme\Dirty\Service\Exporter">
    <arguments>
      <argument name="cache" xsi:type="object">Acme\Dirty\Model\Cache\ExportCache</argument>
    </arguments>
  </type>
</config>
EOF
cat > "$D/Model/ResourceModel/Widget/Collection.php" <<'EOF'
<?php
declare(strict_types=1);
namespace Acme\Dirty\Model\ResourceModel\Widget;

use Magento\Framework\Model\ResourceModel\Db\Collection\AbstractCollection;

class Collection extends AbstractCollection
{
    protected function _construct()
    {
        $this->_init(\Acme\Dirty\Model\Widget::class, \Acme\Dirty\Model\ResourceModel\Widget::class);
    }
}
EOF

# SI-07 — form XML whose root data argument has no `template` item.
# SI-08 — dynamicRows whose dataScope repeats its own name.
cat > "$D/view/adminhtml/ui_component/acme_dirty_widget_form.xml" <<'EOF'
<?xml version="1.0"?>
<form xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:module:Magento_Ui:etc/ui_configuration.xsd">
  <argument name="data" xsi:type="array">
    <item name="js_config" xsi:type="array">
      <item name="provider" xsi:type="string">acme_dirty_widget_form.widget_form_data_source</item>
    </item>
  </argument>
  <fieldset name="general">
    <dynamicRows name="links">
      <settings>
        <dataScope>links</dataScope>
        <addButtonLabel translate="true">Add Link</addButtonLabel>
      </settings>
    </dynamicRows>
  </fieldset>
</form>
EOF

# Owner module whose acl.xml is AREA-SPECIFIC (etc/adminhtml/acl.xml): its module.xml sits at
# etc/module.xml, one level up. Ownership attribution must find it there.
O="$WORK/app/code/Acme/Owner"
mkdir -p "$O/etc/adminhtml"
cat > "$O/etc/module.xml" <<'EOF'
<?xml version="1.0"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:framework:Module/etc/module.xsd">
  <module name="Acme_Owner"/>
</config>
EOF
cat > "$O/etc/adminhtml/acl.xml" <<'EOF'
<?xml version="1.0"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:framework:Acl/etc/acl.xsd">
  <acl>
    <resources>
      <resource id="Magento_Backend::admin">
        <resource id="Magento_Backend::stores">
          <resource id="Magento_Backend::stores_settings">
            <resource id="Acme_Owner::hub" title="Owner Hub" sortOrder="30"/>
          </resource>
        </resource>
      </resource>
    </resources>
  </acl>
</config>
EOF

# SI-09 — foreign ACL id re-declared under the wrong parent (missing stores_settings level).
cat > "$D/etc/acl.xml" <<'EOF'
<?xml version="1.0"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:framework:Acl/etc/acl.xsd">
  <acl>
    <resources>
      <resource id="Magento_Backend::admin">
        <resource id="Magento_Backend::stores">
          <resource id="Magento_Config::config">
            <resource id="Acme_Dirty::config" title="Acme Dirty" sortOrder="10"/>
          </resource>
          <resource id="Acme_Owner::hub" title="Stolen Hub" sortOrder="40"/>
          <resource id="Magento_Backend::stores_nonexistent">
            <resource id="Acme_Dirty::orphan" title="Acme Dirty Orphan" sortOrder="20"/>
          </resource>
        </resource>
      </resource>
    </resources>
  </acl>
</config>
EOF

# SI-11 — template posts to an action path with an underscore; the router turns `_` into `\`.
cat > "$D/etc/frontend/routes.xml" <<'EOF'
<?xml version="1.0"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:framework:App/etc/routes.xsd">
  <router id="standard">
    <route id="acmedirty" frontName="acmedirty">
      <module name="Acme_Dirty"/>
    </route>
  </router>
</config>
EOF
cat > "$D/Controller/Login/AuthenticatePost.php" <<'EOF'
<?php
declare(strict_types=1);
namespace Acme\Dirty\Controller\Login;

use Magento\Framework\App\Action\Action;

class AuthenticatePost extends Action
{
    public function execute()
    {
        return $this->resultRedirectFactory->create();
    }
}
EOF
cat > "$D/view/frontend/templates/login/authenticate.phtml" <<'EOF'
<form method="post" action="<?= $escaper->escapeUrl($block->getUrl('acmedirty/login/authenticate_post')) ?>">
    <button type="submit"><?= $escaper->escapeHtml(__('Confirm')) ?></button>
</form>
EOF

# ---------------------------------------------------------------------------
# CLEAN fixture — every surface complete, plus the shapes most likely to be
# mistaken for violations. MUST produce zero findings.
# ---------------------------------------------------------------------------
C="$WORK/app/code/Acme/Clean"
mkdir -p "$C/etc/adminhtml" "$C/etc/frontend" "$C/Model/ResourceModel/Widget/Grid" \
         "$C/Model/Cache" "$C/Controller/Login" "$C/Controller/Account/Edit" \
         "$C/view/adminhtml/ui_component" "$C/view/frontend/templates/login" "$C/Service" "$C/Ui"

cat > "$C/etc/module.xml" <<'EOF'
<?xml version="1.0"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:framework:Module/etc/module.xsd">
  <module name="Acme_Clean"/>
</config>
EOF
cat > "$C/etc/communication.xml" <<'EOF'
<?xml version="1.0"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:framework:Communication/etc/communication.xsd">
  <topic name="acme.clean.export" request="Acme\Clean\Api\Data\ExportInterface">
    <handler name="default" type="Acme\Clean\Model\ExportHandler" method="process"/>
  </topic>
</config>
EOF
cat > "$C/etc/queue_publisher.xml" <<'EOF'
<?xml version="1.0"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:framework:MessageQueue:etc/publisher.xsd">
  <publisher topic="acme.clean.export">
    <connection name="db" exchange="magento-db"/>
  </publisher>
</config>
EOF
cat > "$C/etc/queue_topology.xml" <<'EOF'
<?xml version="1.0"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:framework:MessageQueue:etc/topology.xsd">
  <exchange name="magento-db" type="topic" connection="db">
    <binding id="AcmeCleanExport" topic="acme.clean.export" destinationType="queue" destination="acme.clean.export.queue"/>
  </exchange>
</config>
EOF
cat > "$C/etc/queue_consumer.xml" <<'EOF'
<?xml version="1.0"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:framework:Communication/etc/consumer.xsd">
  <consumer name="acme.clean.export" queue="acme.clean.export.queue" connection="db" handler="Acme\Clean\Model\ExportHandler::process"/>
</config>
EOF
cat > "$C/etc/cache.xml" <<'EOF'
<?xml version="1.0"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:framework:Cache/etc/cache.xsd">
  <type name="acme_clean_export" translate="label,description" instance="Acme\Clean\Model\Cache\ExportCache">
    <label>Acme Clean Export</label>
    <description>Cached export payloads</description>
  </type>
</config>
EOF
cat > "$C/Model/Cache/ExportCache.php" <<'EOF'
<?php
declare(strict_types=1);
namespace Acme\Clean\Model\Cache;

use Magento\Framework\Cache\Frontend\Decorator\TagScope;
use Magento\Framework\App\Cache\Type\FrontendPool;

class ExportCache extends TagScope
{
    public const TYPE_IDENTIFIER = 'acme_clean_export';
    public const CACHE_TAG = 'ACME_CLEAN_EXPORT';

    public function __construct(FrontendPool $currentFrontendPool)
    {
        parent::__construct($currentFrontendPool->get(self::TYPE_IDENTIFIER), self::CACHE_TAG);
    }
}
EOF
# Correctly typed against FrontendInterface — must NOT trip SI-05.
cat > "$C/Service/Exporter.php" <<'EOF'
<?php
declare(strict_types=1);
namespace Acme\Clean\Service;

use Magento\Framework\Cache\FrontendInterface;

class Exporter
{
    private $cache;

    public function __construct(FrontendInterface $cache)
    {
        $this->cache = $cache;
    }
}
EOF
# A second service that legitimately takes App\CacheInterface but is NOT wired to the
# custom cache type — must NOT trip SI-05.
cat > "$C/Service/PageCacheReader.php" <<'EOF'
<?php
declare(strict_types=1);
namespace Acme\Clean\Service;

use Magento\Framework\App\CacheInterface;

class PageCacheReader
{
    public function __construct(private CacheInterface $cache)
    {
    }
}
EOF
# Grid collection registration in the GLOBAL di.xml, pointing at a SearchResult subclass.
cat > "$C/etc/di.xml" <<'EOF'
<?xml version="1.0"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:framework:ObjectManager/etc/config.xsd">
  <type name="Magento\Framework\View\Element\UiComponent\DataProvider\CollectionFactory">
    <arguments>
      <argument name="collections" xsi:type="array">
        <item name="acme_clean_widget_listing_data_source" xsi:type="string">Acme\Clean\Model\ResourceModel\Widget\Grid\Collection</item>
      </argument>
    </arguments>
  </type>
  <type name="Acme\Clean\Service\Exporter">
    <arguments>
      <argument name="cache" xsi:type="object">Acme\Clean\Model\Cache\ExportCache</argument>
    </arguments>
  </type>
</config>
EOF
cat > "$C/Model/ResourceModel/Widget/Grid/Collection.php" <<'EOF'
<?php
declare(strict_types=1);
namespace Acme\Clean\Model\ResourceModel\Widget\Grid;

use Magento\Framework\View\Element\UiComponent\DataProvider\SearchResult;

class Collection extends SearchResult
{
    protected function _initSelect()
    {
        parent::_initSelect();
    }
}
EOF
# A listing whose data source is a CUSTOM DataProvider class (no `collections` entry at all) —
# the documented alternative to the SearchResult bridge. Must NOT trip SI-06.
cat > "$C/Ui/WidgetDataProvider.php" <<'EOF'
<?php
declare(strict_types=1);
namespace Acme\Clean\Ui;

use Magento\Ui\DataProvider\AbstractDataProvider;

class WidgetDataProvider extends AbstractDataProvider
{
    public function getData()
    {
        return [];
    }
}
EOF
mkdir -p "$C/etc/adminhtml"
cat > "$C/etc/adminhtml/di.xml" <<'EOF'
<?xml version="1.0"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:framework:ObjectManager/etc/config.xsd">
  <!-- A CollectionFactory block customised for something OTHER than `collections`, with a
       class-like string in an unrelated array. Neither SI-10 nor SI-06 may key off the block. -->
  <type name="Magento\Framework\View\Element\UiComponent\DataProvider\CollectionFactory">
    <arguments>
      <argument name="someOtherOption" xsi:type="array">
        <item name="handler" xsi:type="string">Acme\Clean\Model\ResourceModel\Widget\Collection</item>
      </argument>
    </arguments>
  </type>
</config>
EOF
# A plain entity collection that is NOT registered as a grid data source — SI-06 must ignore it.
mkdir -p "$C/Model/ResourceModel/Widget"
cat > "$C/Model/ResourceModel/Widget/Collection.php" <<'EOF'
<?php
declare(strict_types=1);
namespace Acme\Clean\Model\ResourceModel\Widget;

use Magento\Framework\Model\ResourceModel\Db\Collection\AbstractCollection;

class Collection extends AbstractCollection
{
    protected function _construct()
    {
        $this->_init(\Acme\Clean\Model\Widget::class, \Acme\Clean\Model\ResourceModel\Widget::class);
    }
}
EOF
cat > "$C/view/adminhtml/ui_component/acme_clean_widget_form.xml" <<'EOF'
<?xml version="1.0"?>
<form xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:module:Magento_Ui:etc/ui_configuration.xsd">
  <argument name="data" xsi:type="array">
    <item name="js_config" xsi:type="array">
      <item name="provider" xsi:type="string">acme_clean_widget_form.widget_form_data_source</item>
    </item>
    <item name="template" xsi:type="string">templates/form/collapsible</item>
  </argument>
  <fieldset name="general">
    <dynamicRows name="links">
      <settings>
        <addButtonLabel translate="true">Add Link</addButtonLabel>
      </settings>
    </dynamicRows>
    <dynamicRows name="records">
      <settings>
        <dataScope>record_rows</dataScope>
      </settings>
    </dynamicRows>
  </fieldset>
</form>
EOF
# Foreign ACL ids re-declared at their canonical parents — attach-only, must NOT trip SI-09.
cat > "$C/etc/acl.xml" <<'EOF'
<?xml version="1.0"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:framework:Acl/etc/acl.xsd">
  <acl>
    <resources>
      <resource id="Magento_Backend::admin">
        <resource id="Magento_Backend::stores">
          <resource id="Magento_Backend::stores_settings">
            <resource id="Magento_Config::config">
              <resource id="Acme_Clean::config" title="Acme Clean" sortOrder="10"/>
            </resource>
          </resource>
        </resource>
      </resource>
    </resources>
  </acl>
</config>
EOF
cat > "$C/etc/frontend/routes.xml" <<'EOF'
<?xml version="1.0"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:framework:App/etc/routes.xsd">
  <router id="standard">
    <route id="acmeclean" frontName="acmeclean">
      <module name="Acme_Clean"/>
    </route>
  </router>
</config>
EOF
# A 2-segment URL (`route/controller`) defaults the action to `index`, so Index.php must exist.
cat > "$C/Controller/Login/Index.php" <<'EOF'
<?php
declare(strict_types=1);
namespace Acme\Clean\Controller\Login;

use Magento\Framework\App\Action\Action;

class Index extends Action
{
    public function execute()
    {
        return $this->resultFactory->create('page');
    }
}
EOF
cat > "$C/Controller/Login/AuthenticatePost.php" <<'EOF'
<?php
declare(strict_types=1);
namespace Acme\Clean\Controller\Login;

use Magento\Framework\App\Action\Action;

class AuthenticatePost extends Action
{
    public function execute()
    {
        return $this->resultRedirectFactory->create();
    }
}
EOF
# A genuinely nested controller: the URL underscore maps to a sub-namespace that EXISTS.
# Must NOT trip SI-11.
cat > "$C/Controller/Account/Edit/Save.php" <<'EOF'
<?php
declare(strict_types=1);
namespace Acme\Clean\Controller\Account\Edit;

use Magento\Framework\App\Action\Action;

class Save extends Action
{
    public function execute()
    {
        return $this->resultRedirectFactory->create();
    }
}
EOF
cat > "$C/view/frontend/templates/login/authenticate.phtml" <<'EOF'
<form method="post" action="<?= $escaper->escapeUrl($block->getUrl('acmeclean/login/authenticatePost')) ?>">
    <button type="submit"><?= $escaper->escapeHtml(__('Confirm')) ?></button>
</form>
<a href="<?= $escaper->escapeUrl($block->getUrl('acmeclean/account_edit/save')) ?>">Save</a>
<a href="<?= $escaper->escapeUrl($block->getUrl('checkout/cart/index')) ?>">Cart</a>
<a href="<?= $escaper->escapeUrl($block->getUrl('acmeclean/login')) ?>">Login index</a>
EOF

# ---------------------------------------------------------------------------
run_checker() {
    # run_checker <module-path> <out.json>
    local mod="$1" out="$2" rc=0
    TARGET_PATH="$mod" SCAN_ROOT="$WORK/app/code" MAGENTO_ROOT="$WORK" \
        FINDINGS_FILE="$out" bash "$CHECKER" >"$out.stdout" 2>"$out.stderr" || rc=$?
    echo "$rc"
}

ids_of() {
    python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(' '.join(sorted(f.get('subcategory','?') for f in d)))
" "$1"
}

# --- dirty fixture: every rule fires, exactly once -----------------------------------------
rc="$(run_checker "$D" "$WORK/dirty.json")"
[ "$rc" = "0" ] || fail "checker exited $rc on the dirty fixture (stderr: $(cat "$WORK/dirty.json.stderr"))"
if [ ! -f "$WORK/dirty.json" ]; then
    fail "no findings file produced for the dirty fixture"
else
    got="$(ids_of "$WORK/dirty.json")"
    want="SI-01 SI-02 SI-03 SI-04 SI-05 SI-06 SI-07 SI-08 SI-09 SI-09 SI-10 SI-11 SI-12"
    [ "$got" = "$want" ] || fail "dirty fixture rule ids
  want: $want
  got:  $got"

    # Every finding must satisfy the shared findings schema's required fields.
    python3 - "$WORK/dirty.json" <<'PY' || fail "dirty findings violate the shared schema"
import json,sys
req = ('id','severity','category','title','evidence','recommendation','verification')
bad = []
for f in json.load(open(sys.argv[1])):
    for k in req:
        if not f.get(k):
            bad.append(f"{f.get('subcategory','?')}: missing {k}")
    if f.get('category') != 'surface':
        bad.append(f"{f.get('subcategory','?')}: category {f.get('category')!r} != 'surface'")
    if f.get('severity') not in ('critical','high','medium','low','info'):
        bad.append(f"{f.get('subcategory','?')}: bad severity {f.get('severity')!r}")
    for e in f.get('evidence') or []:
        if not e.get('file') or not isinstance(e.get('line'), int) or e['line'] < 1:
            bad.append(f"{f.get('subcategory','?')}: evidence needs file + 1-based line, got {e}")
if bad:
    print('\n'.join(bad)); sys.exit(1)
PY

    # The ACL lockout is a total admin outage — it must not be filed as a nicety.
    sev="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(next(f['severity'] for f in d if f['subcategory']=='SI-09'))
" "$WORK/dirty.json")"
    [ "$sev" = "critical" ] || fail "SI-09 (admin lockout) severity should be critical, got $sev"

    # Evidence must point at the file that actually has to change.
    python3 - "$WORK/dirty.json" <<'PY' || fail "dirty findings point at the wrong file"
import json,sys
want = {
 'SI-01': 'etc/communication.xml', 'SI-02': 'etc/communication.xml',
 'SI-03': 'etc/queue_consumer.xml', 'SI-04': 'Model/Cache/ExportCache.php',
 'SI-05': 'Service/Exporter.php',   'SI-06': 'Model/ResourceModel/Widget/Collection.php',
 'SI-07': 'view/adminhtml/ui_component/acme_dirty_widget_form.xml',
 'SI-08': 'view/adminhtml/ui_component/acme_dirty_widget_form.xml',
 'SI-09': 'etc/acl.xml', 'SI-10': 'etc/adminhtml/di.xml', 'SI-12': 'etc/acl.xml',
 'SI-11': 'view/frontend/templates/login/authenticate.phtml',
}
bad=[]
for f in json.load(open(sys.argv[1])):
    rule=f['subcategory']; files=[e['file'] for e in f['evidence']]
    if not any(want[rule] in p for p in files):
        bad.append(f"{rule}: expected evidence in {want[rule]}, got {files}")
if bad:
    print('\n'.join(bad)); sys.exit(1)
PY
fi

# --- clean fixture: silence. A rule that fires here is worse than no rule. -----------------
rc="$(run_checker "$C" "$WORK/clean.json")"
[ "$rc" = "0" ] || fail "checker exited $rc on the clean fixture (stderr: $(cat "$WORK/clean.json.stderr"))"
if [ -f "$WORK/clean.json" ]; then
    got="$(ids_of "$WORK/clean.json")"
    [ -z "$got" ] || fail "clean fixture must produce zero findings, got: $got
$(python3 -c "
import json,sys
for f in json.load(open('$WORK/clean.json')): print('   ',f['subcategory'],f['title'],[e['file'] for e in f['evidence']])
")"
fi

# --- degradation must be loud, never silent -----------------------------------------------
# With no vendor tree the ACL reference set is incomplete, so SI-09 cannot be decided. The
# checker must say so on stderr (build-findings turns stderr into `scanner_errors`) instead of
# reporting a clean ACL.
NOVENDOR="$WORK/novendor"
mkdir -p "$NOVENDOR/app/code/Acme"
cp -r "$D" "$NOVENDOR/app/code/Acme/Dirty"
rc=0
TARGET_PATH="$NOVENDOR/app/code/Acme/Dirty" SCAN_ROOT="$NOVENDOR/app/code" MAGENTO_ROOT="$NOVENDOR" \
    FINDINGS_FILE="$WORK/novendor.json" bash "$CHECKER" >/dev/null 2>"$WORK/novendor.stderr" || rc=$?
[ "$rc" = "0" ] || fail "checker exited $rc with no vendor tree"
grep -qi "acl" "$WORK/novendor.stderr" \
    || fail "missing vendor ACL reference set must be reported on stderr, got: $(cat "$WORK/novendor.stderr")"
ids="$(ids_of "$WORK/novendor.json" 2>/dev/null || echo '')"
case "$ids" in
    *SI-09*) fail "SI-09 must not be asserted when the ACL reference set is unavailable" ;;
esac

# --- a module with none of these surfaces is silent, not skipped-with-noise ----------------
E="$WORK/app/code/Acme/Empty"
mkdir -p "$E/etc"
cat > "$E/etc/module.xml" <<'EOF'
<?xml version="1.0"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="urn:magento:framework:Module/etc/module.xsd">
  <module name="Acme_Empty"/>
</config>
EOF
rc="$(run_checker "$E" "$WORK/empty.json")"
[ "$rc" = "0" ] || fail "checker exited $rc on a module with no relevant surfaces"
got="$(ids_of "$WORK/empty.json" 2>/dev/null || echo '')"
[ -z "$got" ] || fail "surface-less module must produce zero findings, got: $got"

# --- malformed XML must be reported, not swallowed ----------------------------------------
B="$WORK/app/code/Acme/Broken"
mkdir -p "$B/etc"
cat > "$B/etc/module.xml" <<'EOF'
<?xml version="1.0"?>
<config><module name="Acme_Broken"/></config>
EOF
printf '<?xml version="1.0"?>\n<config><topic name="x.y"\n' > "$B/etc/communication.xml"
rc=0
TARGET_PATH="$B" SCAN_ROOT="$WORK/app/code" MAGENTO_ROOT="$WORK" \
    FINDINGS_FILE="$WORK/broken.json" bash "$CHECKER" >/dev/null 2>"$WORK/broken.stderr" || rc=$?
[ "$rc" = "0" ] || fail "checker exited $rc on malformed XML (it must degrade, not crash)"
grep -q "communication.xml" "$WORK/broken.stderr" \
    || fail "unparseable XML must be named on stderr, got: $(cat "$WORK/broken.stderr")"

exit "$FAIL"
