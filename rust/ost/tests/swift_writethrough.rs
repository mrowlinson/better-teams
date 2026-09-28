//! R13 token-store lane: Swift write-through bytes must parse as `Config`.
//! Golden TOML mirrors `TokenStoreTests.testTOMLGoldenRoundTrip` exactly
//! (same text the Swift `TokenTOML.serialize` emits); if Swift changes the
//! shape, update both. Read-only: no disk writes.

use ost::auth::TokenStore;
use ost::config::Config;

const SWIFT_GOLDEN: &str = "refresh_token = \"FIXTURE-RT\"\n\
     tenant_id = \"FIXTURE-TENANT\"\n\
     region_gtms = \"{\\\"a\\\":1}\"\n\
     [access_token]\n\
     token = \"FIXTURE-AAD\"\n\
     expires_at = 1800003600\n\
     [skype_token]\n\
     token = \"FIXTURE-SKYPE\"\n\
     [graph_token]\n\
     token = \"FIXTURE-GRAPH\"\n\
     expires_at = 1800003600\n\
     [ic3_token]\n\
     token = \"FIXTURE-IC3\"\n\
     expires_at = 1800003600\n\
     [recorder_token]\n\
     token = \"FIXTURE-REC\"\n\
     expires_at = 1800003600\n";

#[test]
fn swift_writethrough_parses_as_config() {
    let cfg: Config = toml::from_str(SWIFT_GOLDEN).expect("Swift TOML parses");
    assert_eq!(cfg.get_access_token().unwrap().token, "FIXTURE-AAD");
    assert_eq!(
        cfg.get_access_token().unwrap().expires_at,
        Some(1_800_003_600)
    );
    assert_eq!(cfg.get_refresh_token().as_deref(), Some("FIXTURE-RT"));
    assert_eq!(cfg.tenant_id.as_deref(), Some("FIXTURE-TENANT"));
    assert_eq!(cfg.get_skype_token().unwrap().token, "FIXTURE-SKYPE");
    assert_eq!(cfg.get_skype_token().unwrap().expires_at, None);
    assert_eq!(cfg.get_graph_token().unwrap().token, "FIXTURE-GRAPH");
    assert_eq!(cfg.get_ic3_token().unwrap().token, "FIXTURE-IC3");
    assert_eq!(
        cfg.get_recorder_token().unwrap().token,
        "FIXTURE-REC"
    );
    let gtms = cfg.get_region_gtms().expect("region_gtms JSON");
    assert_eq!(gtms.get("a").and_then(|v| v.as_i64()), Some(1));
}
