#!/usr/local/bin/php
<?php
// OPNsense Redis 플러그인을 헤드리스로 켠다.
//   GUI/API 없이 모델을 저장한다 — 모델 노드는 저장 시점에 기본값으로
//   생성되므로, config.xml 을 손으로 만들면 필드가 빠져 템플릿 렌더가
//   'has no attribute slowlog' 로 실패한다.
require_once("config.inc");
require_once("util.inc");
require_once("/usr/local/opnsense/mvc/script/load_phalcon.php");

$mdl = new \OPNsense\Redis\Redis();
$mdl->general->enabled = "1";
$val = $mdl->performValidation();
if ($val->count() > 0) {
    foreach ($val as $msg) { echo "VALIDATION: " . $msg->getField() . " " . $msg->getMessage() . "\n"; }
    exit(1);
}
$mdl->serializeToConfig();
\OPNsense\Core\Config::getInstance()->save();
echo "redis enabled via model\n";
