//! OAuth2 device code flow for Azure AD, plus Skype token exchange

use anyhow::{Context, Result};
use oauth2::{
    basic::{BasicClient, BasicErrorResponseType},
    AuthUrl, ClientId, DeviceAuthorizationUrl, RefreshToken, RequestTokenError, Scope,
    StandardDeviceAuthorizationResponse, TokenResponse, TokenUrl,
};

use super::skype::exchange_skype_token;
use super::{AuthConfig, TokenStore};
use crate::config::Config;

/// Build the OAuth2 client from an AuthConfig
fn build_client(auth_config: &AuthConfig) -> Result<BasicClient> {
    let auth_url = AuthUrl::new(format!(
        "https://login.microsoftonline.com/{}/oauth2/v2.0/authorize",
        auth_config.tenant
    ))?;
    let token_url = TokenUrl::new(format!(
        "https://login.microsoftonline.com/{}/oauth2/v2.0/token",
        auth_config.tenant
    ))?;
    let device_url = DeviceAuthorizationUrl::new(format!(
        "https://login.microsoftonline.com/{}/oauth2/v2.0/devicecode",
        auth_config.tenant
    ))?;

    Ok(BasicClient::new(
        ClientId::new(auth_config.client_id.to_string()),
        None,
        auth_url,
        Some(token_url),
    )
    .set_device_authorization_url(device_url))
}

/// Acquire an IC3 token by exchanging the refresh token with IC3 scope.
async fn acquire_ic3_token(
    client: &BasicClient,
    refresh_token_str: &str,
) -> Result<(String, Option<u64>)> {
    let token_response = client
        .exchange_refresh_token(&RefreshToken::new(refresh_token_str.to_string()))
        .add_scope(Scope::new(
            "https://ic3.teams.office.com/.default".to_string(),
        ))
        .add_scope(Scope::new("offline_access".to_string()))
        .request_async(oauth2::reqwest::async_http_client)
        .await
        .context("Failed to acquire IC3 token")?;

    Ok((
        token_response.access_token().secret().to_string(),
        token_response.expires_in().map(|d| d.as_secs()),
    ))
}

/// Acquire a recorder service AAD token (audience: 4580fd1d-e5a3-4f56-9ad1-aab0e3bf8f76).
async fn acquire_recorder_token(
    client: &BasicClient,
    refresh_token_str: &str,
) -> Result<(String, Option<u64>)> {
    let token_response = client
        .exchange_refresh_token(&RefreshToken::new(refresh_token_str.to_string()))
        .add_scope(Scope::new(
            "4580fd1d-e5a3-4f56-9ad1-aab0e3bf8f76/.default".to_string(),
        ))
        .add_scope(Scope::new("offline_access".to_string()))
        .request_async(oauth2::reqwest::async_http_client)
        .await
        .context("Failed to acquire recorder token")?;

    Ok((
        token_response.access_token().secret().to_string(),
        token_response.expires_in().map(|d| d.as_secs()),
    ))
}

/// Acquire a Graph API token by exchanging the refresh token with Graph scope.
async fn acquire_graph_token(
    client: &BasicClient,
    refresh_token_str: &str,
) -> Result<(String, Option<u64>)> {
    let token_response = client
        .exchange_refresh_token(&RefreshToken::new(refresh_token_str.to_string()))
        .add_scope(Scope::new(
            "https://graph.microsoft.com/.default".to_string(),
        ))
        .add_scope(Scope::new("offline_access".to_string()))
        .request_async(oauth2::reqwest::async_http_client)
        .await
        .context("Failed to acquire Graph token")?;

    Ok((
        token_response.access_token().secret().to_string(),
        token_response.expires_in().map(|d| d.as_secs()),
    ))
}

/// Refresh the AAD access token using a stored refresh_token, then
/// re-exchange for a Skype token. Returns Ok(true) if refresh succeeded.
pub async fn refresh() -> Result<bool> {
    refresh_for(&crate::config::active_profile()).await
}

/// Same as [`refresh`], scoped to one account profile (multi-account:
/// per-account refresh without switching the active profile).
pub async fn refresh_for(profile: &str) -> Result<bool> {
    refresh_for_with(profile, live_main_exchange, true).await
}

/// One refresh-token grant against the token endpoint (TOKEN-REFRESH-RACE
/// seam: production uses [`live_main_exchange`]; tests inject a stub IdP
/// with single-use rotating refresh tokens, zero live traffic).
#[derive(Debug, Clone)]
pub struct RefreshedTokens {
    pub access_token: String,
    pub expires_in: Option<u64>,
    /// Rotated refresh token, when the IdP issued one.
    pub refresh_token: Option<String>,
}

/// Production grant: one AAD refresh-token exchange (Skype scope).
async fn live_main_exchange(refresh_token: String) -> Result<RefreshedTokens> {
    let auth_config = AuthConfig::default();
    let client = build_client(&auth_config)?;

    tracing::info!("Refreshing AAD token...");

    let token_response = client
        .exchange_refresh_token(&RefreshToken::new(refresh_token))
        .add_scope(Scope::new(
            "https://api.spaces.skype.com/.default".to_string(),
        ))
        .add_scope(Scope::new("offline_access".to_string()))
        .request_async(oauth2::reqwest::async_http_client)
        .await
        .map_err(|e| {
            // Burned/expired/revoked refresh token: distinct, non-retryable.
            let typed_invalid = matches!(
                &e,
                RequestTokenError::ServerResponse(r)
                    if matches!(r.error(), BasicErrorResponseType::InvalidGrant)
            );
            if typed_invalid || format!("{:#}", &e).contains("invalid_grant") {
                let detail = match &e {
                    RequestTokenError::ServerResponse(r) => r
                        .error_description()
                        .map(|d| d.lines().next().unwrap_or("").to_string())
                        .filter(|d| !d.is_empty())
                        .unwrap_or_else(|| "invalid_grant".to_string()),
                    _ => "invalid_grant".to_string(),
                };
                return anyhow::Error::new(ReauthRequired { detail });
            }
            anyhow::Error::new(e).context("Failed to refresh AAD token")
        })?;

    Ok(RefreshedTokens {
        access_token: token_response.access_token().secret().to_string(),
        expires_in: token_response.expires_in().map(|d| d.as_secs()),
        refresh_token: token_response
            .refresh_token()
            .map(|rt| rt.secret().to_string()),
    })
}

/// The stored refresh token was rejected by the IdP (`invalid_grant`:
/// burned, expired, or revoked). Not retryable: the user must sign in
/// again. Callers must fail fast with a re-auth message, never retry.
#[derive(Debug, thiserror::Error)]
#[error("stored session expired (refresh token rejected: {detail}); run `teams-cli login` to sign in again")]
pub struct ReauthRequired {
    /// First line of the IdP error description (never secrets).
    pub detail: String,
}

/// True when `e` is (or wraps) [`ReauthRequired`); the message-substring
/// fallback covers grant errors already formatted as `… invalid_grant …`
/// (see `post_token_grant`), which carry no typed marker.
pub fn is_reauth_required(e: &anyhow::Error) -> bool {
    if e.downcast_ref::<ReauthRequired>().is_some() {
        return true;
    }
    format!("{:#}", e).contains("invalid_grant")
}

/// Per-profile in-process single-flight: concurrent `refresh_for` calls in
/// this process serialize here; cross-process callers serialize on the
/// profile lockfile (held across the SAME critical section, so the two
/// compose into one global exclusion per profile).
fn inflight_for(profile: &str) -> std::sync::Arc<tokio::sync::Mutex<()>> {
    static SLOTS: std::sync::OnceLock<
        std::sync::Mutex<std::collections::HashMap<String, std::sync::Arc<tokio::sync::Mutex<()>>>>,
    > = std::sync::OnceLock::new();
    let map = SLOTS.get_or_init(Default::default);
    let mut guard = map.lock().unwrap_or_else(|e| e.into_inner());
    guard
        .entry(profile.to_string())
        .or_insert_with(|| std::sync::Arc::new(tokio::sync::Mutex::new(())))
        .clone()
}

/// Max time a refresher waits for another process's hold before failing
/// loud (retryable [`crate::config::ProfileBusy`], never `ReauthRequired`:
/// contention is not a burned credential). Worst legit hold is one main
/// grant plus the derived chain (Skype/Graph/IC3/recorder), each
/// HTTP-bounded; 90s covers a slow-but-alive holder, and the
/// post-timeout adoption re-read saves the common case where the winner
/// just finished while we waited.
const PROFILE_LOCK_WAIT: std::time::Duration = std::time::Duration::from_secs(90);

/// Acquire the profile lockfile without stalling the async runtime
/// (blocking `flock` runs on the blocking pool), waiting at most
/// [`PROFILE_LOCK_WAIT`].
async fn acquire_profile_lock(profile: &str) -> Result<crate::config::ProfileFileLock> {
    acquire_profile_lock_for(profile, PROFILE_LOCK_WAIT).await
}

/// [`acquire_profile_lock`] with an explicit wait (tests pass seconds;
/// production uses [`PROFILE_LOCK_WAIT`]).
async fn acquire_profile_lock_for(
    profile: &str,
    wait: std::time::Duration,
) -> Result<crate::config::ProfileFileLock> {
    let owned = profile.to_string();
    tokio::task::spawn_blocking(move || Config::try_lock_profile_exclusive(&owned, wait))
        .await
        .context("profile lock task failed")?
}

/// [`refresh_for`] with an injectable main grant and a derived-token switch
/// (tests pass `false`: no Skype/Graph/IC3/recorder calls, zero traffic).
///
/// Race protocol (all under per-profile in-process single-flight AND the
/// cross-process profile lockfile, held across read-exchange-write):
///  1. snapshot the stored refresh and access tokens;
///  2. re-read from disk once the locks are held; if the refresh token
///     rotated OR the access token changed, another process already
///     refreshed -> adopt it (invalidate cache) and return WITHOUT any
///     exchange. Comparing token STRINGS (not validity) is what makes
///     solo proactive refresh keep working: with no winner the re-read
///     is identical to the snapshot, so a still-valid access token does
///     NOT suppress the exchange (the missing-derived-token path in
///     `login` depends on that);
///  3. otherwise exchange exactly once;
///  4. NEVER persist on failure (no downgrade writes: a burned store stays
///     exactly as it was, so a later sign-in is not clobbered).
/// Lock contention fails loud: on [`crate::config::ProfileBusy`] the
/// waiter re-reads once (adopting a winner that just finished) and
/// otherwise returns the retryable busy error — never `ReauthRequired`.
async fn refresh_for_with<E, F>(profile: &str, exchange: E, acquire_derived: bool) -> Result<bool>
where
    E: Fn(String) -> F + Send + Sync,
    F: std::future::Future<Output = Result<RefreshedTokens>> + Send,
{
    refresh_for_with_wait(profile, exchange, acquire_derived, PROFILE_LOCK_WAIT).await
}

/// [`refresh_for_with`] with an explicit lock wait (tests pass seconds).
async fn refresh_for_with_wait<E, F>(
    profile: &str,
    exchange: E,
    acquire_derived: bool,
    lock_wait: std::time::Duration,
) -> Result<bool>
where
    E: Fn(String) -> F + Send + Sync,
    F: std::future::Future<Output = Result<RefreshedTokens>> + Send,
{
    let snapshot = Config::load_cached_for(profile)?;
    let refresh_token_str = match snapshot.get_refresh_token() {
        Some(rt) => rt,
        None => return Ok(false),
    };
    let snapshot_at = snapshot.get_access_token().map(|t| t.token);

    // (a) in-process single-flight.
    let slot = inflight_for(profile);
    let _inproc = slot.lock().await;
    // (b) cross-process exclusion, held across re-read + exchange + write.
    let _file = match acquire_profile_lock_for(profile, lock_wait).await {
        Ok(g) => g,
        Err(e) if crate::config::is_profile_busy(&e) => {
            // Contended the whole wait: adopt a winner that finished
            // meanwhile, else fail loud (retryable, not burned).
            let fresh = Config::load_for(profile)?;
            let rt_now = fresh.get_refresh_token();
            let at_now = fresh.get_access_token().map(|t| t.token);
            if rt_now.as_deref() != Some(refresh_token_str.as_str()) || at_now != snapshot_at {
                Config::invalidate_cache_for(profile);
                return Ok(rt_now.is_some());
            }
            return Err(e);
        }
        Err(e) => return Err(e),
    };

    // (c) re-read under the locks; skip the exchange when already fresh.
    // (`rt_now == None` lands here too — signed out elsewhere —
    // returning Ok(false).)
    let fresh = Config::load_for(profile)?;
    let rt_now = fresh.get_refresh_token();
    let at_now = fresh.get_access_token().map(|t| t.token);
    if rt_now.as_deref() != Some(refresh_token_str.as_str()) || at_now != snapshot_at {
        // Winner already persisted: adopt, no exchange.
        Config::invalidate_cache_for(profile);
        return Ok(rt_now.is_some());
    }
    let mut config = fresh;

    // (d) exactly one exchange; on failure persist NOTHING.
    let new_tokens = exchange(refresh_token_str).await?;

    config.set_access_token(new_tokens.access_token, new_tokens.expires_in);

    if let Some(new_rt) = new_tokens.refresh_token {
        config.set_refresh_token(new_rt);
    }

    // Derived tokens (Skype/Graph/IC3/recorder): live traffic, skipped
    // by stub-IdP tests (`acquire_derived = false`).
    if acquire_derived {
        let auth_config = AuthConfig::default();
        let client = build_client(&auth_config)?;

        // Exchange for Skype token
        let aad_token = config
            .get_access_token()
            .map(|t| t.token)
            .unwrap_or_default();
        match exchange_skype_token(&aad_token, false).await {
            Ok((skype_tok, expires_in, region_gtms)) => {
                config.set_skype_token(skype_tok, expires_in);
                if let Some(gtms) = region_gtms {
                    config.set_region_gtms(gtms);
                }
                tracing::info!("Skype token refreshed");
            }
            Err(e) => {
                tracing::warn!("Skype token exchange failed during refresh: {:#}", e);
            }
        }

        // Acquire Graph API token (separate audience)
        let rt_for_graph = config.get_refresh_token().unwrap_or_default();
        if !rt_for_graph.is_empty() {
            match acquire_graph_token(&client, &rt_for_graph).await {
                Ok((graph_tok, expires_in)) => {
                    config.set_graph_token(graph_tok, expires_in);
                    tracing::info!("Graph token acquired");
                }
                Err(e) => {
                    tracing::warn!("Graph token acquisition failed: {:#}", e);
                }
            }
        }

        // Acquire IC3 token (for Trouter WebSocket auth)
        let rt_for_ic3 = config.get_refresh_token().unwrap_or_default();
        if !rt_for_ic3.is_empty() {
            match acquire_ic3_token(&client, &rt_for_ic3).await {
                Ok((ic3_tok, expires_in)) => {
                    config.set_ic3_token(ic3_tok, expires_in);
                    tracing::info!("IC3 token acquired");
                }
                Err(e) => {
                    tracing::warn!("IC3 token acquisition failed: {:#}", e);
                }
            }
        }

        // Acquire recorder service token (for call recording)
        let rt_for_recorder = config.get_refresh_token().unwrap_or_default();
        if !rt_for_recorder.is_empty() {
            match acquire_recorder_token(&client, &rt_for_recorder).await {
                Ok((rec_tok, expires_in)) => {
                    config.set_recorder_token(rec_tok, expires_in);
                    tracing::info!("Recorder token acquired");
                }
                Err(e) => {
                    tracing::warn!("Recorder token acquisition failed: {:#}", e);
                }
            }
        }
    }

    config.save_to(profile)?;
    tracing::info!("Token refresh complete");
    Ok(true)
}

/// Graph delegated scopes requested at device-code consent time
/// (SCOPE-EXPAND lane, 2026-11-19).
///
/// WHY: five live lanes hit 403 walls on one root cause — the device
/// token carries only the app's current consented set, and that set comes
/// from THIS request, not from re-logging in. Extending this list is what
/// broadens the grant; the owner re-consents once (device flow) and the
/// blocked lanes re-run green.
///
/// Ordering constraint: the v2.0 endpoint returns the initial access token
/// for the resource named by the FIRST scope, so the Skype resource scope
/// stays first and the fresh AAD token keeps working for the authsvc Skype
/// exchange below. The refresh token carries consent for every scope here;
/// [`acquire_graph_token`] redeems `graph/.default` from that same grant,
/// so no other code path needs to change.
pub const DEVICE_REQUEST_GRAPH_SCOPES: &[&str] = &[
    // webinarslive: POST + GET /solutions/virtualEvents/webinars both 403.
    "https://graph.microsoft.com/VirtualEvent.ReadWrite",
    // sigprove: POST /me/onlineMeetings + /communications/onlineMeetings 403.
    "https://graph.microsoft.com/OnlineMeetings.ReadWrite",
    // channelsprivlive: archive/unarchive 403 names this scope.
    "https://graph.microsoft.com/ChannelSettings.ReadWrite.All",
    // channelsprivlive: channel delete 403 names this scope
    // (Group.ReadWrite.All below is the documented alternative).
    "https://graph.microsoft.com/Channel.Delete.All",
    // teammodlive: PATCH /groups (visibility) 403; also channel-delete alternative.
    "https://graph.microsoft.com/Group.ReadWrite.All",
    // serverreprobe: GET /me/chats 403.
    "https://graph.microsoft.com/Chat.ReadWrite",
    // serverreprobe: GET beta /me/teamwork 403 names both scopes.
    "https://graph.microsoft.com/UserTeamwork.Read",
    "https://graph.microsoft.com/User.Read.All",
];

/// Perform OAuth2 login flow
pub async fn login(force: bool) -> Result<()> {
    {
        let config = Config::load_cached()?;

        // Check for existing valid token
        if !force {
            if let Some(token) = config.get_access_token() {
                if !token.is_expired() {
                    // Check if any derived tokens are missing; if so, refresh to acquire them
                    let missing_tokens =
                        config.get_recorder_token().is_none() || config.get_ic3_token().is_none();
                    if missing_tokens && config.get_refresh_token().is_some() {
                        tracing::info!(
                            "AAD token valid but some derived tokens missing, refreshing..."
                        );
                        match refresh().await {
                            Ok(true) => {
                                println!("Tokens refreshed (acquired missing derived tokens).");
                                return Ok(());
                            }
                            Err(e) if is_reauth_required(&e) => {
                                // Burned stored token, access still valid for
                                // now: single attempt, no retry; re-auth can
                                // wait until expiry (or --force now).
                                eprintln!("Stored refresh token rejected ({:#}); access token still valid. Run with --force to sign in again now.", e);
                            }
                            _ => {}
                        }
                    }
                    println!(
                        "Already logged in (AAD token valid). Use --force to re-authenticate."
                    );
                    return Ok(());
                }
                // Try refresh before falling through to device code
                if config.get_refresh_token().is_some() {
                    tracing::info!("AAD token expired, attempting refresh...");
                    match refresh().await {
                        Ok(true) => {
                            println!("Token refreshed successfully.");
                            return Ok(());
                        }
                        Ok(false) => {}
                        Err(e) => {
                            if is_reauth_required(&e) {
                                // Single attempt, no retry: the device-code
                                // flow below IS the re-auth.
                                eprintln!("Stored session expired ({:#}); signing in again.", e);
                            } else {
                                tracing::warn!(
                                    "Refresh failed, falling back to device code: {:#}",
                                    e
                                );
                            }
                        }
                    }
                }
            }
        }
    }

    let auth_config = AuthConfig::default();
    let client = build_client(&auth_config)?;

    // Use device code flow for CLI
    tracing::info!("Initiating device code flow...");

    // Skype resource scope FIRST: the v2.0 endpoint audiences the initial
    // access token to the resource of the first scope, and the authsvc
    // Skype exchange below needs that audience unchanged.
    let mut device_request = client
        .exchange_device_code()?
        .add_scope(Scope::new(
            "https://api.spaces.skype.com/.default".to_string(),
        ))
        .add_scope(Scope::new("offline_access".to_string()));
    for scope in DEVICE_REQUEST_GRAPH_SCOPES {
        device_request = device_request.add_scope(Scope::new(scope.to_string()));
    }
    let device_auth_response: StandardDeviceAuthorizationResponse = device_request
        .request_async(oauth2::reqwest::async_http_client)
        .await
        .context("Failed to request device code")?;

    let verification_url = device_auth_response.verification_uri().as_str();
    let user_code = device_auth_response.user_code().secret();

    println!();
    println!("To sign in, visit: {}", verification_url);
    println!("Enter code:        {}", user_code);
    println!();

    // Poll for token
    tracing::info!("Waiting for authentication...");

    let token_response = client
        .exchange_device_access_token(&device_auth_response)
        .request_async(oauth2::reqwest::async_http_client, tokio::time::sleep, None)
        .await
        .context("Failed to exchange device code for token")?;

    // Save AAD tokens (single load-mutate-save)
    let mut config = Config::load_cached()?;
    config.set_access_token(
        token_response.access_token().secret().to_string(),
        token_response.expires_in().map(|d| d.as_secs()),
    );

    if let Some(refresh_token) = token_response.refresh_token() {
        config.set_refresh_token(refresh_token.secret().to_string());
    }

    // Exchange for Skype token
    let aad_token = token_response.access_token().secret();
    let mut skype_ok = false;
    match exchange_skype_token(aad_token, false).await {
        Ok((skype_tok, expires_in, region_gtms)) => {
            config.set_skype_token(skype_tok, expires_in);
            if let Some(gtms) = region_gtms {
                config.set_region_gtms(gtms);
            }
            skype_ok = true;
        }
        Err(e) => {
            tracing::warn!("Skype token exchange failed: {:#}", e);
            eprintln!("Warning: Skype token exchange failed; some operations may not work.");
        }
    }

    // Acquire Graph API token (separate audience from Skype token)
    let mut graph_ok = false;
    if let Some(ref rt) = config.get_refresh_token() {
        let auth_config = AuthConfig::default();
        let client = build_client(&auth_config)?;
        match acquire_graph_token(&client, rt).await {
            Ok((graph_tok, expires_in)) => {
                config.set_graph_token(graph_tok, expires_in);
                graph_ok = true;
            }
            Err(e) => {
                tracing::warn!("Graph token acquisition failed: {:#}", e);
                eprintln!("Warning: Graph token acquisition failed; whoami/chats may not work.");
            }
        }
    }

    // Acquire IC3 token (for Trouter WebSocket auth)
    let mut ic3_ok = false;
    if let Some(ref rt) = config.get_refresh_token() {
        let auth_config = AuthConfig::default();
        let client = build_client(&auth_config)?;
        match acquire_ic3_token(&client, rt).await {
            Ok((ic3_tok, expires_in)) => {
                config.set_ic3_token(ic3_tok, expires_in);
                ic3_ok = true;
            }
            Err(e) => {
                tracing::warn!("IC3 token acquisition failed: {:#}", e);
                eprintln!("Warning: IC3 token acquisition failed; trouter may not work.");
            }
        }
    }

    // Acquire recorder service token (for call recording)
    let mut recorder_ok = false;
    if let Some(ref rt) = config.get_refresh_token() {
        let auth_config = AuthConfig::default();
        let client = build_client(&auth_config)?;
        match acquire_recorder_token(&client, rt).await {
            Ok((rec_tok, expires_in)) => {
                config.set_recorder_token(rec_tok, expires_in);
                recorder_ok = true;
            }
            Err(e) => {
                tracing::warn!("Recorder token acquisition failed: {:#}", e);
                eprintln!("Warning: Recorder token acquisition failed; recording may not work.");
            }
        }
    }

    config.save()?;
    if skype_ok && graph_ok && ic3_ok && recorder_ok {
        println!("Login successful.");
    } else {
        println!(
            "Login partially successful (missing: {}).",
            [
                (!skype_ok).then_some("Skype"),
                (!graph_ok).then_some("Graph"),
                (!ic3_ok).then_some("IC3"),
                (!recorder_ok).then_some("Recorder")
            ]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(", ")
        );
    }
    Ok(())
}

/// Clear stored credentials
pub async fn logout() -> Result<()> {
    let mut config = Config::load_cached()?;
    config.clear_tokens();
    config.save()?;
    println!("Logged out.");
    Ok(())
}

/// Display current auth status
pub async fn status() -> Result<()> {
    let config = Config::load_cached()?;

    // AAD token status
    match config.get_access_token() {
        Some(token) if !token.is_expired() => {
            println!("AAD token:   valid");
            if let Some(exp) = token.expires_at {
                println!("  expires_at: {}", exp);
            }
        }
        Some(_) => {
            println!("AAD token:   expired");
        }
        None => {
            println!("AAD token:   none");
        }
    }

    // Refresh token
    match config.get_refresh_token() {
        Some(_) => println!("Refresh tok: present"),
        None => println!("Refresh tok: none"),
    }

    // Graph token status
    match config.get_graph_token() {
        Some(token) if !token.is_expired() => {
            println!("Graph token: valid");
            if let Some(exp) = token.expires_at {
                println!("  expires_at: {}", exp);
            }
        }
        Some(_) => {
            println!("Graph token: expired");
        }
        None => {
            println!("Graph token: none");
        }
    }

    // IC3 token status
    match config.get_ic3_token() {
        Some(token) if !token.is_expired() => {
            println!("IC3 token:   valid");
            if let Some(exp) = token.expires_at {
                println!("  expires_at: {}", exp);
            }
        }
        Some(_) => {
            println!("IC3 token:   expired");
        }
        None => {
            println!("IC3 token:   none");
        }
    }

    // Recorder token status
    match config.get_recorder_token() {
        Some(token) if !token.is_expired() => {
            println!("Recorder tk: valid");
            if let Some(exp) = token.expires_at {
                println!("  expires_at: {}", exp);
            }
        }
        Some(_) => {
            println!("Recorder tk: expired");
        }
        None => {
            println!("Recorder tk: none");
        }
    }

    // Skype token status
    match config.get_skype_token() {
        Some(token) if !token.is_expired() => {
            println!("Skype token: valid");
            if let Some(exp) = token.expires_at {
                println!("  expires_at: {}", exp);
            }
        }
        Some(_) => {
            println!("Skype token: expired");
        }
        None => {
            println!("Skype token: none");
        }
    }

    // Region GTMs
    if config.region_gtms.is_some() {
        println!("Region GTMs: present");
    } else {
        println!("Region GTMs: none");
    }

    if config.get_access_token().is_none() {
        println!("\nRun 'teams-cli login' to authenticate.");
    }

    Ok(())
}

// MARK: - Token broker (any scope + nested app auth)
//
// A TeamsJS host answers `authentication.getAuthToken` (the app's
// `webApplicationInfo.resource`) and MSAL.js nested-app-auth `GetToken`
// requests. Both are refresh-token grants on the stored Teams refresh
// token: plain for a resource/scope, brokered (`brk_client_id`) for a
// nested app's own client id. Tokens are cached in memory per
// (profile, client, scopes) and never logged.

/// One minted access token. `Debug` never prints the token.
#[derive(Clone)]
pub struct TokenGrant {
    pub access_token: String,
    pub expires_in: Option<u64>,
    pub scope: Option<String>,
    /// OIDC id token (NAA grants ask for `openid`: MSAL.js rejects a
    /// nested-app-auth reply without one). Never printed.
    pub id_token: Option<String>,
    /// Rotated refresh token, when the IdP issued one (broker grants carry
    /// `offline_access`, so they rotate the server-side RT chain: the
    /// caller must persist this or the stored RT burns). Never printed.
    pub refresh_token: Option<String>,
}

impl std::fmt::Debug for TokenGrant {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TokenGrant")
            .field("access_token", &format_args!("<{} chars>", self.access_token.len()))
            .field("expires_in", &self.expires_in)
            .field("scope", &self.scope)
            .field("id_token", &self.id_token.as_ref().map(|t| format!("<{} chars>", t.len())))
            .field("refresh_token", &self.refresh_token.as_ref().map(|t| format!("<{} chars>", t.len())))
            .finish()
    }
}

/// AAD v2 token endpoint for a tenant (`common`, a tenant id, …).
pub fn token_endpoint(tenant: &str) -> String {
    format!("https://login.microsoftonline.com/{}/oauth2/v2.0/token", tenant)
}

/// A resource (`https://x.sharepoint.com`, `api://host/guid`, a bare
/// app id) becomes `<resource>/.default`; anything that already names a
/// scope (`…/.default`, `https://graph.microsoft.com/User.Read`,
/// `openid`) is kept. Space-separated lists are normalized per item,
/// deduplicated, in order.
pub fn normalize_scopes(input: &str) -> String {
    let mut out: Vec<String> = Vec::new();
    for raw in input.split_whitespace() {
        let s = raw.trim_end_matches('/');
        let scope = if s.ends_with("/.default") || !s.contains(['/', ':', '-']) {
            // Already `.default`, or an OIDC scope (openid, profile, …).
            s.to_string()
        } else if let Some(rest) = s.strip_prefix("api://") {
            if rest.is_empty() { continue; }
            // api://host/guid is a resource; api://host/guid/scope a scope
            // only when the last segment is not a GUID-like id.
            let last = rest.rsplit('/').next().unwrap_or(rest);
            if rest.contains('/') && !looks_like_id(last) {
                s.to_string()
            } else {
                format!("{}/.default", s)
            }
        } else if let Ok(u) = url::Url::parse(s) {
            if matches!(u.scheme(), "https" | "http") && (u.path().is_empty() || u.path() == "/") {
                format!("{}/.default", s)
            } else {
                s.to_string()
            }
        } else if looks_like_id(s) {
            format!("{}/.default", s)
        } else {
            s.to_string()
        };
        if !out.contains(&scope) {
            out.push(scope);
        }
    }
    out.join(" ")
}

fn looks_like_id(s: &str) -> bool {
    s.len() == 36 && s.chars().all(|c| c.is_ascii_hexdigit() || c == '-')
}

/// Refresh-token grant form for `scopes` on `client_id`.
pub fn scope_grant_form(client_id: &str, refresh_token: &str, scopes: &str) -> Vec<(String, String)> {
    vec![
        ("client_id".into(), client_id.into()),
        ("grant_type".into(), "refresh_token".into()),
        ("refresh_token".into(), refresh_token.into()),
        ("scope".into(), format!("{} offline_access", normalize_scopes(scopes))),
    ]
}

/// Brokered (nested app auth) redirect for an app origin:
/// `https://tasks.example.com` → `brk-multihub://tasks.example.com`.
pub fn naa_redirect_uri(origin: &str) -> Option<String> {
    let u = url::Url::parse(origin).ok()?;
    let host = u.host_str()?;
    Some(match u.port() {
        Some(p) => format!("brk-multihub://{}:{}", host, p),
        None => format!("brk-multihub://{}", host),
    })
}

/// The hub's own registered redirect (Teams client `1fec8e78`, native
/// public client), sent as `brk_redirect_uri` in brokered grants.
pub const HUB_REDIRECT_URI: &str = "https://login.microsoftonline.com/common/oauth2/nativeclient";

/// Brokered refresh-token grant: the hub (`broker_client_id`, our
/// Teams client) mints a token for a nested app's own client id.
/// `redirect_uri` is the nested app's `brk-multihub://<host>` and
/// `brk_redirect_uri` the hub's own redirect. Verified live 2026-09-28
/// (APPLIVE, Planner's client): the hub redirect plus NO `Origin`
/// header succeeds; the app's brk-multihub URI as `brk_redirect_uri`
/// fails AADSTS50011, and any `Origin` fails AADSTS9002326 (a native
/// client's refresh token cannot be redeemed cross-origin).
pub fn naa_grant_form(
    broker_client_id: &str,
    nested_client_id: &str,
    refresh_token: &str,
    scopes: &str,
    redirect_uri: &str,
) -> Vec<(String, String)> {
    vec![
        ("client_id".into(), nested_client_id.into()),
        ("grant_type".into(), "refresh_token".into()),
        ("refresh_token".into(), refresh_token.into()),
        ("scope".into(), naa_scope(scopes)),
        ("brk_client_id".into(), broker_client_id.into()),
        ("brk_redirect_uri".into(), HUB_REDIRECT_URI.into()),
        ("redirect_uri".into(), redirect_uri.into()),
    ]
}

/// NAA grant scope: the app's scopes plus the OIDC scopes (the reply to
/// MSAL.js needs an id token, as the Teams hub's does), deduplicated.
pub fn naa_scope(scopes: &str) -> String {
    let mut out: Vec<String> = normalize_scopes(scopes).split_whitespace().map(String::from).collect();
    for s in ["openid", "profile", "offline_access"] {
        if !out.iter().any(|o| o.eq_ignore_ascii_case(s)) {
            out.push(s.to_string());
        }
    }
    out.join(" ")
}

/// POSTs one token grant. Errors carry the AAD error code and the first
/// line of its description only (never request or response secrets).
pub async fn post_token_grant(
    http: &reqwest::Client,
    url: &str,
    form: &[(String, String)],
    origin: Option<&str>,
) -> Result<TokenGrant> {
    let mut req = http.post(url).form(form);
    if let Some(o) = origin {
        req = req.header("Origin", o);
    }
    let resp = req.send().await.context("token endpoint unreachable")?;
    let status = resp.status();
    let v: serde_json::Value = resp.json().await.unwrap_or(serde_json::Value::Null);
    if !status.is_success() {
        let code = v.get("error").and_then(|e| e.as_str()).unwrap_or("unknown_error");
        let desc = v
            .get("error_description")
            .and_then(|e| e.as_str())
            .and_then(|d| d.lines().next())
            .unwrap_or("");
        anyhow::bail!("token grant failed (HTTP {}): {} {}", status.as_u16(), code, desc);
    }
    let access_token = v
        .get("access_token")
        .and_then(|t| t.as_str())
        .filter(|t| !t.is_empty())
        .context("token response has no access_token")?
        .to_string();
    Ok(TokenGrant {
        access_token,
        expires_in: v.get("expires_in").and_then(|e| e.as_u64().or_else(|| e.as_str()?.parse().ok())),
        scope: v.get("scope").and_then(|s| s.as_str()).map(String::from),
        id_token: v.get("id_token").and_then(|t| t.as_str()).filter(|t| !t.is_empty()).map(String::from),
        refresh_token: v.get("refresh_token").and_then(|t| t.as_str()).filter(|t| !t.is_empty()).map(String::from),
    })
}

type GrantCache = std::sync::Mutex<std::collections::HashMap<String, (TokenGrant, std::time::Instant)>>;

fn grant_cache() -> &'static GrantCache {
    static CACHE: std::sync::OnceLock<GrantCache> = std::sync::OnceLock::new();
    CACHE.get_or_init(Default::default)
}

/// Cached grant still valid for at least 5 minutes, with its remaining
/// lifetime as `expires_in`.
fn cached_grant(key: &str) -> Option<TokenGrant> {
    let cache = grant_cache().lock().unwrap_or_else(|e| e.into_inner());
    let (g, until) = cache.get(key)?;
    let left = until.checked_duration_since(std::time::Instant::now())?;
    if left.as_secs() < 300 {
        return None;
    }
    Some(TokenGrant { expires_in: Some(left.as_secs()), ..g.clone() })
}

fn store_grant(key: String, g: &TokenGrant) {
    let life = std::time::Duration::from_secs(g.expires_in.unwrap_or(3600));
    grant_cache()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(key, (g.clone(), std::time::Instant::now() + life));
}

/// Drops every cached grant of one profile (sign-out / account switch).
pub fn clear_grants_for(profile: &str) {
    let prefix = format!("{}|", profile);
    grant_cache()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .retain(|k, _| !k.starts_with(&prefix));
}

/// Access token for any resource or scope (`getAuthToken`), minted with
/// the stored Teams refresh token on the Teams client id.
pub async fn token_for_scope_for(profile: &str, scopes: &str) -> Result<TokenGrant> {
    let auth = AuthConfig::default();
    let endpoint = token_endpoint(auth.tenant);
    token_for_scope_for_with(profile, scopes, move |form| {
        let endpoint = endpoint.clone();
        let http = crate::api::client::shared_http();
        async move { post_token_grant(&http, &endpoint, &form, None).await }
    })
    .await
}

/// [`token_for_scope_for`] with an injectable grant POST (tests pass a
/// stub IdP, zero live traffic). Joins the same exclusion as the refresh
/// path (per-profile in-process single-flight + cross-process lockfile):
/// broker grants carry `offline_access`, so each one rotates the
/// server-side RT chain — concurrent unlocked callers redeem the same RT
/// and burn it (TOKENRACE-R2 gap (a)). Same-scope losers re-hit the
/// winner's cached grant (one exchange); the rotated RT is persisted so
/// the store stays on the chain tip. Failures persist nothing.
async fn token_for_scope_for_with<X, F>(profile: &str, scopes: &str, exchange: X) -> Result<TokenGrant>
where
    X: Fn(Vec<(String, String)>) -> F + Send + Sync,
    F: std::future::Future<Output = Result<TokenGrant>> + Send,
{
    let scopes = normalize_scopes(scopes);
    anyhow::ensure!(!scopes.is_empty(), "no scope");
    let auth = AuthConfig::default();
    let key = format!("{}|{}|{}", profile, auth.client_id, scopes);
    if let Some(g) = cached_grant(&key) {
        return Ok(g);
    }
    broker_grant_with(profile, &key, exchange, |rt| {
        scope_grant_form(auth.client_id, &rt, &scopes)
    })
    .await
}

/// Shared broker exclusion: single-flight + lockfile, cache re-check
/// (same-scope winner), redeem the FRESH stored RT, persist rotation.
async fn broker_grant_with<X, F>(
    profile: &str,
    key: &str,
    exchange: X,
    form_for: impl Fn(String) -> Vec<(String, String)>,
) -> Result<TokenGrant>
where
    X: Fn(Vec<(String, String)>) -> F + Send + Sync,
    F: std::future::Future<Output = Result<TokenGrant>> + Send,
{
    let slot = inflight_for(profile);
    let _inproc = slot.lock().await;
    let _file = acquire_profile_lock(profile).await?;
    if let Some(g) = cached_grant(key) {
        return Ok(g);
    }
    let mut stored = Config::load_for(profile)?;
    let rt = stored
        .get_refresh_token()
        .context("No refresh token. Sign in again.")?;
    let g = exchange(form_for(rt.clone())).await?;
    if let Some(new_rt) = g.refresh_token.clone() {
        if new_rt != rt {
            stored.set_refresh_token(new_rt);
            stored.save_to(profile)?;
        }
    }
    store_grant(key.to_string(), &g);
    Ok(g)
}

/// Nested app auth token: `client_id` is the nested app's AAD client,
/// `origin` its page origin (redirect `brk-multihub://<host>`). The
/// grant is sent without an `Origin` header (see [`naa_grant_form`]).
pub async fn naa_token_for(profile: &str, client_id: &str, scopes: &str, origin: &str) -> Result<TokenGrant> {
    let auth = AuthConfig::default();
    let endpoint = token_endpoint(auth.tenant);
    naa_token_for_with(profile, client_id, scopes, origin, move |form| {
        let endpoint = endpoint.clone();
        let http = crate::api::client::shared_http();
        async move { post_token_grant(&http, &endpoint, &form, None).await }
    })
    .await
}

/// [`naa_token_for`] with an injectable grant POST (tests pass a stub
/// IdP, zero live traffic). Same exclusion as [`token_for_scope_for_with`]
/// (NAA grants rotate the RT chain the same way).
async fn naa_token_for_with<X, F>(
    profile: &str,
    client_id: &str,
    scopes: &str,
    origin: &str,
    exchange: X,
) -> Result<TokenGrant>
where
    X: Fn(Vec<(String, String)>) -> F + Send + Sync,
    F: std::future::Future<Output = Result<TokenGrant>> + Send,
{
    let scopes = normalize_scopes(scopes);
    anyhow::ensure!(!scopes.is_empty(), "no scope");
    anyhow::ensure!(!client_id.trim().is_empty(), "no client id");
    let redirect = naa_redirect_uri(origin).context("bad app origin")?;
    let auth = AuthConfig::default();
    let key = format!("{}|{}|{}|{}", profile, client_id, redirect, scopes);
    if let Some(g) = cached_grant(&key) {
        return Ok(g);
    }
    broker_grant_with(profile, &key, exchange, |rt| {
        naa_grant_form(auth.client_id, client_id, &rt, &scopes, &redirect)
    })
    .await
}

#[cfg(test)]
mod broker_tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[test]
    fn scopes_normalize() {
        assert_eq!(normalize_scopes("https://contoso.sharepoint.com"), "https://contoso.sharepoint.com/.default");
        assert_eq!(normalize_scopes("https://contoso.sharepoint.com/"), "https://contoso.sharepoint.com/.default");
        assert_eq!(
            normalize_scopes("api://tasks.example.com/11111111-2222-3333-4444-555555555555"),
            "api://tasks.example.com/11111111-2222-3333-4444-555555555555/.default"
        );
        assert_eq!(normalize_scopes("api://tasks.example.com/abc/access_as_user"), "api://tasks.example.com/abc/access_as_user");
        assert_eq!(
            normalize_scopes("75f31797-37c9-498e-8dc9-53c16a36afca"),
            "75f31797-37c9-498e-8dc9-53c16a36afca/.default"
        );
        assert_eq!(
            normalize_scopes("https://graph.microsoft.com/User.Read openid openid https://graph.microsoft.com/.default"),
            "https://graph.microsoft.com/User.Read openid https://graph.microsoft.com/.default"
        );
        assert_eq!(normalize_scopes("  "), "");
    }

    /// SCOPE-EXPAND pin: the device-code consent request must carry exactly
    /// this scope set — the two pre-existing scopes plus the eight
    /// verified-missing Graph delegated scopes. Any add/remove/reorder here
    /// changes what the owner consents to at re-login, so fail loud.
    #[test]
    fn device_request_scope_set_pinned() {
        // Pre-existing scopes (unchanged behavior anchor).
        let base = [
            "https://api.spaces.skype.com/.default",
            "offline_access",
        ];
        // Verified-missing Graph scopes, one per blocked lane (see
        // DEVICE_REQUEST_GRAPH_SCOPES docs). Full-URL form: the request
        // spans two resources and short names would be ambiguous.
        let added = [
            "https://graph.microsoft.com/VirtualEvent.ReadWrite",
            "https://graph.microsoft.com/OnlineMeetings.ReadWrite",
            "https://graph.microsoft.com/ChannelSettings.ReadWrite.All",
            "https://graph.microsoft.com/Channel.Delete.All",
            "https://graph.microsoft.com/Group.ReadWrite.All",
            "https://graph.microsoft.com/Chat.ReadWrite",
            "https://graph.microsoft.com/UserTeamwork.Read",
            "https://graph.microsoft.com/User.Read.All",
        ];
        // Exact set, exact order (Skype first: fixes the access-token audience).
        let expected: Vec<&str> = base.into_iter().chain(added).collect();
        let actual: Vec<&str> = base.into_iter().chain(DEVICE_REQUEST_GRAPH_SCOPES.iter().copied()).collect();
        assert_eq!(actual, expected, "device consent scope set changed: {actual:?}");
        assert_eq!(
            DEVICE_REQUEST_GRAPH_SCOPES.len(),
            8,
            "additions must stay minimal (8): {:?}",
            DEVICE_REQUEST_GRAPH_SCOPES
        );
        // Hygiene: no duplicates, no blanks, no graph /.default (explicit only).
        let mut seen = std::collections::HashSet::new();
        for s in base.into_iter().chain(DEVICE_REQUEST_GRAPH_SCOPES.iter().copied()) {
            assert!(!s.trim().is_empty(), "blank scope requested");
            assert!(!s.contains(' '), "scope contains whitespace: {s}");
            assert!(seen.insert(s), "duplicate scope requested: {s}");
        }
        assert!(
            !DEVICE_REQUEST_GRAPH_SCOPES.contains(&"https://graph.microsoft.com/.default"),
            "graph scopes must stay explicit, never /.default"
        );
    }

    #[test]
    fn grant_forms() {
        let f = scope_grant_form("hub", "RT", "https://x.sharepoint.com");
        assert!(f.contains(&("scope".into(), "https://x.sharepoint.com/.default offline_access".into())));
        assert_eq!(naa_scope("api://a/x openid"), "api://a/x openid profile offline_access");
        assert!(f.contains(&("client_id".into(), "hub".into())));
        assert_eq!(naa_redirect_uri("https://tasks.example.com/teamsui/x").as_deref(), Some("brk-multihub://tasks.example.com"));
        assert_eq!(naa_redirect_uri("http://localhost:8080").as_deref(), Some("brk-multihub://localhost:8080"));
        assert_eq!(naa_redirect_uri("not a url"), None);
        let n = naa_grant_form("hub", "nested", "RT", "User.Read", "brk-multihub://a.example.com");
        assert!(n.contains(&("client_id".into(), "nested".into())));
        assert!(n.contains(&("brk_client_id".into(), "hub".into())));
        assert!(n.contains(&("redirect_uri".into(), "brk-multihub://a.example.com".into())));
        assert!(n.contains(&("brk_redirect_uri".into(), HUB_REDIRECT_URI.into())));
        let dbg = format!("{:?}", TokenGrant { access_token: "SECRET".into(), expires_in: Some(1), scope: None, id_token: Some("IDSECRET".into()), refresh_token: Some("RTSECRET".into()) });
        assert!(!dbg.contains("SECRET") && !dbg.contains("RTSECRET"), "grant Debug must redact secrets: {dbg}");
    }

    /// One-shot HTTP stub: records the raw request, answers `resp`.
    async fn stub(resp: String) -> (String, Arc<Mutex<String>>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let url = format!("http://{}/common/oauth2/v2.0/token", listener.local_addr().expect("addr"));
        let seen = Arc::new(Mutex::new(String::new()));
        let log = seen.clone();
        tokio::spawn(async move {
            let Ok((mut sock, _)) = listener.accept().await else { return };
            let mut buf = Vec::new();
            let mut tmp = [0u8; 4096];
            loop {
                let n = sock.read(&mut tmp).await.unwrap_or(0);
                if n == 0 { break; }
                buf.extend_from_slice(&tmp[..n]);
                let text = String::from_utf8_lossy(&buf).to_string();
                if let Some(end) = text.find("\r\n\r\n") {
                    let len = text[..end]
                        .lines()
                        .find_map(|l| l.to_ascii_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse::<usize>().unwrap_or(0)))
                        .unwrap_or(0);
                    if buf.len() >= end + 4 + len { break; }
                }
            }
            *log.lock().unwrap() = String::from_utf8_lossy(&buf).to_string();
            sock.write_all(resp.as_bytes()).await.ok();
            sock.shutdown().await.ok();
        });
        (url, seen)
    }

    fn http_json(status: &str, body: &str) -> String {
        format!(
            "HTTP/1.1 {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            status,
            body.len(),
            body
        )
    }

    #[tokio::test]
    async fn naa_grant_posts_brokered_form_and_parses() {
        let (url, seen) = stub(http_json(
            "200 OK",
            r#"{"token_type":"Bearer","scope":"User.Read","expires_in":"3599","access_token":"AT-1"}"#,
        ))
        .await;
        let form = naa_grant_form("hub", "nested", "RT", "User.Read", "brk-multihub://a.example.com");
        let g = post_token_grant(&reqwest::Client::new(), &url, &form, None)
            .await
            .expect("grant");
        assert_eq!(g.access_token, "AT-1");
        assert_eq!(g.expires_in, Some(3599));
        let req = seen.lock().unwrap().clone();
        assert!(req.starts_with("POST /common/oauth2/v2.0/token"));
        assert!(!req.to_ascii_lowercase().contains("\norigin:"), "brokered grants carry no Origin");
        assert!(req.contains("brk_client_id=hub"));
        assert!(req.contains("client_id=nested"));
        assert!(req.contains("grant_type=refresh_token"));
        assert!(req.contains("redirect_uri=brk-multihub%3A%2F%2Fa.example.com"));
        assert!(req.contains("brk_redirect_uri=https%3A%2F%2Flogin.microsoftonline.com%2Fcommon%2Foauth2%2Fnativeclient"));
    }

    #[tokio::test]
    async fn grant_error_reports_code_not_secrets() {
        let (url, _) = stub(http_json(
            "400 Bad Request",
            r#"{"error":"invalid_grant","error_description":"AADSTS70000: bad grant.\r\nTrace ID: x"}"#,
        ))
        .await;
        let form = scope_grant_form("hub", "RT-SECRET", "https://x.sharepoint.com");
        let e = post_token_grant(&reqwest::Client::new(), &url, &form, None).await.unwrap_err();
        let msg = format!("{:#}", e);
        assert!(msg.contains("invalid_grant") && msg.contains("AADSTS70000"));
        assert!(!msg.contains("RT-SECRET") && !msg.contains("Trace ID"));
    }

    #[test]
    fn grant_cache_expiry_and_clear() {
        let g = TokenGrant { access_token: "t".into(), expires_in: Some(3600), scope: None, id_token: None, refresh_token: None };
        store_grant("p1|c|s".into(), &g);
        store_grant("p2|c|s".into(), &TokenGrant { expires_in: Some(60), ..g.clone() });
        assert!(cached_grant("p1|c|s").is_some());
        assert!(cached_grant("p2|c|s").is_none(), "under 5 min left = refetch");
        clear_grants_for("p1");
        assert!(cached_grant("p1|c|s").is_none());
    }
}

/// TOKEN-REFRESH-RACE tests: stub IdP (rotating single-use refresh
/// tokens, in-process) + temp-dir stores (`OST_CONFIG_DIR`). ZERO live
/// traffic: `acquire_derived = false`, no HTTP anywhere in this module.
#[cfg(test)]
mod refresh_race_tests {
    use super::*;
    use crate::config::Config;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::{Arc, Mutex};

    /// True when this process is the spawned child for `entry` (env
    /// `TOKENRACE_CHILD` matches): the caller runs its body. Otherwise
    /// spawns that child (which runs ONLY this test via the harness
    /// filter, so the env swap below never shares a process with store
    /// tests like `config::tests`), asserts it passed, and returns false.
    fn in_spawned_child(entry: &str) -> bool {
        if std::env::var("TOKENRACE_CHILD").as_deref() == Ok(entry) {
            return true;
        }
        let exe = std::env::current_exe().expect("test exe");
        let out = std::process::Command::new(&exe)
            .arg("--nocapture")
            .arg(entry)
            .env("TOKENRACE_CHILD", entry)
            .output()
            .expect("spawn child");
        assert!(
            out.status.success(),
            "child {entry} failed:\n{}",
            String::from_utf8_lossy(&out.stderr)
        );
        false
    }

    /// Serializes the tests in this module within one process (they swap
    /// the process-wide `OST_CONFIG_DIR`).
    static STORE_LOCK: Mutex<()> = Mutex::new(());

    /// Temp-dir store with a unique profile. Restores the previous
    /// `OST_CONFIG_DIR` on drop. Hold `STORE_LOCK` while alive.
    struct TempStore {
        _guard: std::sync::MutexGuard<'static, ()>,
        prev: Option<std::ffi::OsString>,
        profile: String,
    }

    impl TempStore {
        fn new(tag: &str) -> Self {
            let guard = STORE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
            let prev = std::env::var_os("OST_CONFIG_DIR");
            let dir = std::env::temp_dir().join(format!(
                "tokenrace-{}-{}-{}",
                tag,
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .expect("clock")
                    .as_nanos()
            ));
            std::fs::create_dir_all(&dir).expect("temp store dir");
            std::env::set_var("OST_CONFIG_DIR", &dir);
            let profile = format!("tokenrace-{}", tag);
            Config::invalidate_cache_for(&profile);
            Self {
                _guard: guard,
                prev,
                profile,
            }
        }

        /// Seed an expired access token + `rt` as the stored refresh token.
        fn seed(&self, rt: &str) {
            let mut cfg = Config::default();
            cfg.set_access_token("AT-OLD".to_string(), Some(0));
            cfg.set_refresh_token(rt.to_string());
            cfg.save_to(&self.profile).expect("seed store");
        }

        /// Seed a still-VALID access token + `rt` (the proactive-refresh
        /// shape: `login`'s missing-derived branch calls `refresh_for`
        /// while the access token is good).
        fn seed_valid(&self, rt: &str) {
            let mut cfg = Config::default();
            cfg.set_access_token("AT-OLD".to_string(), Some(3600));
            cfg.set_refresh_token(rt.to_string());
            cfg.save_to(&self.profile).expect("seed store");
        }
    }

    impl Drop for TempStore {
        fn drop(&mut self) {
            Config::invalidate_cache_for(&self.profile);
            match self.prev.take() {
                Some(v) => std::env::set_var("OST_CONFIG_DIR", v),
                None => std::env::remove_var("OST_CONFIG_DIR"),
            }
        }
    }

    /// Stub IdP: single-use refresh tokens. The FIRST exchange of the
    /// current token wins; any replay of a burned token fails with
    /// `invalid_grant`. Rotating mode issues a fresh RT per win (like AAD
    /// normally does); non-rotating mode re-issues the SAME RT string but
    /// still burns it server-side after one redeem (the TOKENRACE-R2 gap
    /// (b) shape: RT unchanged on disk while the store's access token is
    /// already fresh). `delay` forces caller overlap.
    struct StubIdP {
        state: Mutex<StubState>,
        exchanges: AtomicU64,
        delay: std::time::Duration,
        rotating: bool,
    }

    struct StubState {
        current_rt: String,
        next_id: u64,
        consumed: bool,
    }

    impl StubIdP {
        fn new(rt0: &str, delay: std::time::Duration) -> Arc<Self> {
            Self::new_mode(rt0, delay, true)
        }

        fn new_mode(rt0: &str, delay: std::time::Duration, rotating: bool) -> Arc<Self> {
            Arc::new(Self {
                state: Mutex::new(StubState {
                    current_rt: rt0.to_string(),
                    next_id: 1,
                    consumed: false,
                }),
                exchanges: AtomicU64::new(0),
                delay,
                rotating,
            })
        }

        async fn exchange(self: &Arc<Self>, rt: String) -> Result<RefreshedTokens> {
            self.exchanges.fetch_add(1, Ordering::SeqCst);
            tokio::time::sleep(self.delay).await;
            let mut st = self.state.lock().unwrap_or_else(|e| e.into_inner());
            if rt != st.current_rt || (st.consumed && !self.rotating) {
                anyhow::bail!("token grant failed (HTTP 400): invalid_grant burned token replay");
            }
            st.consumed = true;
            let id = st.next_id;
            st.next_id += 1;
            if self.rotating {
                st.current_rt = format!("RT-{}", id);
                st.consumed = false;
            }
            Ok(RefreshedTokens {
                access_token: format!("AT-{}", id),
                expires_in: Some(3600),
                refresh_token: if self.rotating {
                    Some(st.current_rt.clone())
                } else {
                    None
                },
            })
        }

        /// Broker-shaped stub: redeems the RT from a grant form, same
        /// single-use rules as [`StubIdP::exchange`].
        async fn exchange_form(
            self: &Arc<Self>,
            form: Vec<(String, String)>,
        ) -> Result<TokenGrant> {
            let rt = form
                .iter()
                .find(|(k, _)| k == "refresh_token")
                .map(|(_, v)| v.clone())
                .unwrap_or_default();
            let won = self.exchange(rt).await?;
            Ok(TokenGrant {
                access_token: format!("BROKER-{}", won.access_token),
                expires_in: won.expires_in,
                scope: None,
                id_token: None,
                refresh_token: won.refresh_token,
            })
        }
    }

    /// R0 failing-first: N concurrent refreshes must cost exactly ONE IdP
    /// exchange (single-use RT). Unfixed code: every caller exchanges
    /// (N) and last-writer-wins persists a burned token.
    #[tokio::test]
    async fn concurrent_refresh_costs_one_exchange() {
        if !in_spawned_child("refresh_race_tests::concurrent_refresh_costs_one_exchange") {
            return;
        }
        let store = TempStore::new("race");
        store.seed("RT-0");
        let stub = StubIdP::new("RT-0", std::time::Duration::from_millis(200));

        let mut tasks = Vec::new();
        for _ in 0..8 {
            let s = stub.clone();
            let profile = store.profile.clone();
            tasks.push(tokio::spawn(async move {
                refresh_for_with(
                    &profile,
                    move |rt| {
                        let s = s.clone();
                        async move { s.exchange(rt).await }
                    },
                    false,
                )
                .await
            }));
        }
        let mut results = Vec::new();
        for t in tasks {
            results.push(t.await.expect("task"));
        }
        assert_eq!(
            stub.exchanges.load(Ordering::SeqCst),
            1,
            "single-use RT: exactly one IdP exchange for N concurrent refreshes"
        );
        assert_eq!(
            results.iter().filter(|r| matches!(r, Ok(true))).count(),
            8,
            "every caller must succeed"
        );
        // Losers adopt the winner's tokens (no burned-token persistence).
        let final_cfg = Config::load_cached_for(&store.profile).expect("reload");
        let rt = final_cfg.get_refresh_token().expect("stored rt");
        assert_eq!(rt, stub.state.lock().unwrap().current_rt);
        assert!(final_cfg
            .get_access_token()
            .is_some_and(|t| !t.is_expired()));
        assert_eq!(
            final_cfg.get_access_token().expect("at").token,
            format!("AT-1")
        );
    }

    /// Failure persists nothing: a burned stored token fails every caller
    /// with `ReauthRequired` and the store file stays byte-identical (no
    /// downgrade writes). Exchange count == N proves one attempt each and
    /// no retry loop (a storm would exceed N).
    #[tokio::test]
    async fn failed_refresh_persists_nothing() {
        if !in_spawned_child("refresh_race_tests::failed_refresh_persists_nothing") {
            return;
        }
        let store = TempStore::new("fail");
        store.seed("RT-BURNED");
        let path = Config::config_path_for(&store.profile).expect("path");
        let before = std::fs::read(&path).expect("seeded file");
        let stub = StubIdP::new("RT-ELSEWHERE", std::time::Duration::from_millis(50));

        let mut tasks = Vec::new();
        for _ in 0..4 {
            let s = stub.clone();
            let profile = store.profile.clone();
            tasks.push(tokio::spawn(async move {
                refresh_for_with(
                    &profile,
                    move |rt| {
                        let s = s.clone();
                        async move { s.exchange(rt).await }
                    },
                    false,
                )
                .await
            }));
        }
        let mut reauth = 0;
        for t in tasks {
            let r = t.await.expect("task");
            let e = r.expect_err("burned token must fail");
            assert!(is_reauth_required(&e), "must be ReauthRequired: {:#}", e);
            reauth += 1;
        }
        assert_eq!(reauth, 4);
        assert_eq!(
            stub.exchanges.load(Ordering::SeqCst),
            4,
            "one attempt per caller, no retries"
        );
        Config::invalidate_cache_for(&store.profile);
        assert_eq!(
            std::fs::read(&path).expect("file"),
            before,
            "store untouched on failure"
        );
    }

    #[test]
    fn reauth_required_predicate() {
        let typed = anyhow::Error::new(ReauthRequired { detail: "x".into() });
        assert!(is_reauth_required(&typed));
        let wrapped = typed.context("outer");
        assert!(is_reauth_required(&wrapped));
        let formatted: anyhow::Error =
            anyhow::anyhow!("token grant failed (HTTP 400): invalid_grant nope");
        assert!(is_reauth_required(&formatted));
        let other: anyhow::Error = anyhow::anyhow!("connection refused");
        assert!(!is_reauth_required(&other));
    }

    /// Child-process work for [`profile_lock_serializes_across_processes`]:
    /// one locked read-modify-write of the shared counter. True when the
    /// child env was present (work done). Never creates a `TempStore` (it
    /// would swap `OST_CONFIG_DIR` away from the shared store).
    fn do_child_increment() -> bool {
        let Ok(spec) = std::env::var("TOKENRACE_LOCK_CHILD") else {
            return false;
        };
        let (profile, counter) = spec.split_once('|').expect("spec");
        {
            let _held = Config::lock_profile_exclusive(profile).expect("child lock");
            let n: u64 = std::fs::read_to_string(counter)
                .expect("read")
                .trim()
                .parse()
                .expect("num");
            std::thread::sleep(std::time::Duration::from_millis(100));
            std::fs::write(counter, (n + 1).to_string()).expect("write");
        }
        true
    }

    /// Cross-process exclusion: N child PROCESSES (real OS processes, one
    /// shared lockfile) read-modify-write a counter under the profile lock.
    /// Without the `flock`, parallel readers all see 0 and the final count
    /// is 1; with it, exactly N.
    #[tokio::test]
    async fn profile_lock_serializes_across_processes() {
        if do_child_increment() {
            return;
        }
        if !in_spawned_child("refresh_race_tests::profile_lock_serializes_across_processes") {
            return;
        }
        let store = TempStore::new("lockx");
        let counter = std::env::temp_dir().join(format!(
            "tokenrace-counter-{}-{}.txt",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock")
                .as_nanos()
        ));
        std::fs::write(&counter, "0").expect("counter");
        let exe = std::env::current_exe().expect("test exe");
        let mut kids = Vec::new();
        for _ in 0..4 {
            let spec = format!("{}|{}", store.profile, counter.display());
            kids.push(
                tokio::task::spawn_blocking({
                    let exe = exe.clone();
                    move || {
                        std::process::Command::new(&exe)
                            .arg("refresh_race_tests::lock_child_entry")
                            .env("TOKENRACE_LOCK_CHILD", &spec)
                            .output()
                            .expect("spawn child")
                    }
                })
                .await
                .expect("join"),
            );
        }
        for out in &kids {
            assert!(out.status.success(), "child failed: {:?}", out);
        }
        let n: u64 = std::fs::read_to_string(&counter)
            .expect("read")
            .trim()
            .parse()
            .expect("num");
        assert_eq!(n, kids.len() as u64, "no lost updates across processes");
    }

    /// Entry point for [`profile_lock_serializes_across_processes`] child
    /// processes (matched by substring filter). With the child env set it
    /// does the locked increment; without it (plain suite run) it passes
    /// as a no-op and never spawns.
    #[test]
    fn lock_child_entry() {
        let _ = do_child_increment();
    }

    /// R2 gap (a): N concurrent broker grants redeem the stored RT with NO
    /// exclusion (outside the §98 single-flight + flock). Single-use RT:
    /// one caller wins, the rest get `invalid_grant` on the burned token.
    /// Fixed code: broker paths join the same exclusion, same-scope
    /// losers share the winner's cached grant (exactly one exchange) and
    /// the rotated RT is persisted to the store.
    #[tokio::test]
    async fn broker_concurrent_same_scope_single_exchange() {
        if !in_spawned_child("refresh_race_tests::broker_concurrent_same_scope_single_exchange") {
            return;
        }
        let store = TempStore::new("broker");
        store.seed("RT-0");
        let stub = StubIdP::new("RT-0", std::time::Duration::from_millis(100));

        let mut tasks = Vec::new();
        for _ in 0..4 {
            let s = stub.clone();
            let profile = store.profile.clone();
            tasks.push(tokio::spawn(async move {
                token_for_scope_for_with(&profile, "https://r2broker.example/S1", move |form| {
                    let s = s.clone();
                    async move { s.exchange_form(form).await }
                })
                .await
            }));
        }
        for t in tasks {
            match t.await.expect("task") {
                Ok(_) => {}
                Err(e) => panic!("every broker caller must succeed, got: {:#}", e),
            }
        }
        assert_eq!(
            stub.exchanges.load(Ordering::SeqCst),
            1,
            "same scope: one IdP exchange, losers share the winner's grant"
        );
        let final_cfg = Config::load_cached_for(&store.profile).expect("reload");
        assert_eq!(
            final_cfg.get_refresh_token().expect("stored rt"),
            stub.state.lock().unwrap().current_rt,
            "rotated RT must be persisted"
        );
    }

    /// R2 gap (b): proactive refresh (still-valid access token, e.g.
    /// `login`'s missing-derived branch) racing a winner against a
    /// NON-rotating IdP. The re-read sees an unchanged RT with
    /// `access_was_valid == true`, so the loser redeems the
    /// already-redeemed RT and fails spuriously on a store that is
    /// actually fresh. Fixed code: the loser adopts whenever the access
    /// token changed under it (exactly one exchange, both callers Ok).
    #[tokio::test]
    async fn proactive_refresh_adopts_after_winner_no_rotation() {
        if !in_spawned_child(
            "refresh_race_tests::proactive_refresh_adopts_after_winner_no_rotation",
        ) {
            return;
        }
        let store = TempStore::new("proactive");
        store.seed_valid("RT-0");
        let stub = StubIdP::new_mode("RT-0", std::time::Duration::from_millis(150), false);

        let s = stub.clone();
        let profile = store.profile.clone();
        let first = tokio::spawn(async move {
            refresh_for_with(
                &profile,
                move |rt| {
                    let s = s.clone();
                    async move { s.exchange(rt).await }
                },
                false,
            )
            .await
        });
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        let s = stub.clone();
        let profile = store.profile.clone();
        let second = tokio::spawn(async move {
            refresh_for_with(
                &profile,
                move |rt| {
                    let s = s.clone();
                    async move { s.exchange(rt).await }
                },
                false,
            )
            .await
        });
        let a = first.await.expect("task");
        let b = second.await.expect("task");
        match (&a, &b) {
            (Ok(_), Ok(_)) => {}
            _ => panic!("both callers must succeed (a={a:?}, b={b:?})"),
        }
        assert_eq!(
            stub.exchanges.load(Ordering::SeqCst),
            1,
            "loser must adopt, not redeem"
        );
        let final_cfg = Config::load_cached_for(&store.profile).expect("reload");
        assert!(
            final_cfg
                .get_access_token()
                .is_some_and(|t| !t.is_expired()),
            "store must hold the winner's fresh access token"
        );
    }

    /// Corner-fix guard: a SOLO proactive refresh (still-valid access,
    /// no concurrent winner — `login`'s missing-derived-token path) must
    /// STILL exchange. The string-compare adopt rule only skips when the
    /// re-read differs from the snapshot, and with no winner they are
    /// identical.
    #[tokio::test]
    async fn proactive_solo_refresh_still_exchanges() {
        if !in_spawned_child("refresh_race_tests::proactive_solo_refresh_still_exchanges") {
            return;
        }
        let store = TempStore::new("prosol");
        store.seed_valid("RT-0");
        let stub = StubIdP::new("RT-0", std::time::Duration::ZERO);
        let s = stub.clone();
        let profile = store.profile.clone();
        match refresh_for_with(
            &profile,
            move |rt| {
                let s = s.clone();
                async move { s.exchange(rt).await }
            },
            false,
        )
        .await
        {
            Ok(true) => {}
            other => panic!("solo proactive refresh must exchange (got {other:?})"),
        }
        assert_eq!(
            stub.exchanges.load(Ordering::SeqCst),
            1,
            "no winner: exactly one exchange, not a silent adopt"
        );
    }

    /// R2 gap (c): the profile `flock` used to block with NO timeout — a
    /// process hung mid-exchange stalled every other refresher forever.
    /// Fixed code waits boundedly ([`PROFILE_LOCK_WAIT`], seconds in this
    /// test) and fails loud with retryable `ProfileBusy` — never
    /// `ReauthRequired`. REPLACES the R0 characterization test
    /// `profile_lock_wait_is_unbounded` (which proved the unbounded wait;
    /// reason recorded: the wait is now bounded by construction).
    #[tokio::test]
    async fn refresh_fails_loud_when_lock_busy() {
        if !in_spawned_child("refresh_race_tests::refresh_fails_loud_when_lock_busy") {
            return;
        }
        let store = TempStore::new("lockbusy");
        store.seed("RT-0");
        let stub = StubIdP::new("RT-0", std::time::Duration::ZERO);
        let held = Config::lock_profile_exclusive(&store.profile).expect("hold lock");
        let s = stub.clone();
        let profile = store.profile.clone();
        let t0 = std::time::Instant::now();
        let r = refresh_for_with_wait(
            &profile,
            move |rt| {
                let s = s.clone();
                async move { s.exchange(rt).await }
            },
            false,
            std::time::Duration::from_secs(2),
        )
        .await;
        let waited = t0.elapsed();
        let e = r.expect_err("contended lock must fail, not hang");
        assert!(
            crate::config::is_profile_busy(&e),
            "must be typed ProfileBusy, got: {:#}",
            e
        );
        assert!(
            !is_reauth_required(&e),
            "contention is not a burned credential: {:#}",
            e
        );
        assert!(
            waited < std::time::Duration::from_secs(10),
            "wait must be bounded (took {waited:?})"
        );
        assert_eq!(
            stub.exchanges.load(Ordering::SeqCst),
            0,
            "no exchange while contended"
        );
        // Store untouched: a later retry or sign-in is not clobbered.
        let after = Config::load_for(&store.profile).expect("reload");
        assert_eq!(after.get_refresh_token().as_deref(), Some("RT-0"));
        drop(held);
    }

    /// Gap (a), NAA shape: concurrent nested-app grants share the same
    /// exclusion and the same cache re-check (one exchange per app).
    #[tokio::test]
    async fn naa_concurrent_same_app_single_exchange() {
        if !in_spawned_child("refresh_race_tests::naa_concurrent_same_app_single_exchange") {
            return;
        }
        let store = TempStore::new("naanew");
        store.seed("RT-0");
        let stub = StubIdP::new("RT-0", std::time::Duration::from_millis(100));

        let mut tasks = Vec::new();
        for _ in 0..4 {
            let s = stub.clone();
            let profile = store.profile.clone();
            tasks.push(tokio::spawn(async move {
                naa_token_for_with(
                    &profile,
                    "11111111-2222-3333-4444-555555555555",
                    "User.Read",
                    "https://tasks.r2naa.example/teamsui/x",
                    move |form| {
                        let s = s.clone();
                        async move { s.exchange_form(form).await }
                    },
                )
                .await
            }));
        }
        for t in tasks {
            match t.await.expect("task") {
                Ok(_) => {}
                Err(e) => panic!("every NAA caller must succeed, got: {:#}", e),
            }
        }
        assert_eq!(
            stub.exchanges.load(Ordering::SeqCst),
            1,
            "same app: one IdP exchange, losers share the cached grant"
        );
        let final_cfg = Config::load_cached_for(&store.profile).expect("reload");
        assert_eq!(
            final_cfg.get_refresh_token().expect("stored rt"),
            stub.state.lock().unwrap().current_rt,
            "rotated RT must be persisted"
        );
    }

    /// Gap (a), second shape: concurrent broker grants for DISTINCT scopes
    /// cannot share a cached grant, so each exchanges — sequentially under
    /// the exclusion, each redeeming the FRESH RT left by the previous one.
    /// All succeed (no burn) and the store ends on the chain tip.
    #[tokio::test]
    async fn broker_concurrent_distinct_scopes_all_succeed() {
        if !in_spawned_child("refresh_race_tests::broker_concurrent_distinct_scopes_all_succeed") {
            return;
        }
        let store = TempStore::new("brokermulti");
        store.seed("RT-0");
        let stub = StubIdP::new("RT-0", std::time::Duration::from_millis(50));

        let mut tasks = Vec::new();
        for i in 0..3 {
            let s = stub.clone();
            let profile = store.profile.clone();
            tasks.push(tokio::spawn(async move {
                token_for_scope_for_with(
                    &profile,
                    &format!("https://r2multi.example/S{i}"),
                    move |form| {
                        let s = s.clone();
                        async move { s.exchange_form(form).await }
                    },
                )
                .await
            }));
        }
        for t in tasks {
            match t.await.expect("task") {
                Ok(g) => assert!(
                    g.access_token.starts_with("BROKER-AT-"),
                    "grant shape: {}",
                    g.access_token
                ),
                Err(e) => panic!("every broker caller must succeed, got: {:#}", e),
            }
        }
        assert_eq!(
            stub.exchanges.load(Ordering::SeqCst),
            3,
            "one exchange per distinct scope, chained on fresh RTs"
        );
        let final_cfg = Config::load_cached_for(&store.profile).expect("reload");
        assert_eq!(
            final_cfg.get_refresh_token().expect("stored rt"),
            stub.state.lock().unwrap().current_rt,
            "store ends on the chain tip"
        );
    }
}
