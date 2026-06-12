use idevice::{
    heartbeat::HeartbeatClient,
    remote_pairing::{RemotePairingClient, RpPairingFile, RpPairingSocket},
    rsd::RsdHandshake,
    IdeviceError, RsdService,
};

use log::{error, info};

use std::{
    net::SocketAddrV4,
    str::FromStr,
    sync::{Mutex, OnceLock},
};

type RsdAdapter = idevice::tcp::handle::AdapterHandle;

pub struct CachedRsdConnection {
    pub adapter: RsdAdapter,
    pub handshake: RsdHandshake,
}

// Both the pairing file and the cached tunnel are stored as replaceable slots so
// the user can delete/replace the pairing file at runtime without restarting.
static RPPAIRING_FILE: OnceLock<Mutex<Option<RpPairingFile>>> = OnceLock::new();
static RPPAIRING_RSD_CONNECTION: OnceLock<Mutex<Option<CachedRsdConnection>>> = OnceLock::new();

fn rppairing_file_slot() -> &'static Mutex<Option<RpPairingFile>> {
    RPPAIRING_FILE.get_or_init(|| Mutex::new(None))
}

fn rsd_connection_slot() -> &'static Mutex<Option<CachedRsdConnection>> {
    RPPAIRING_RSD_CONNECTION.get_or_init(|| Mutex::new(None))
}

pub fn set_rppairing_file(pairing_file_string: String) -> Result<(), IdeviceError> {
    let pairing_file = RpPairingFile::from_bytes(pairing_file_string.as_bytes())?;
    *rppairing_file_slot().lock().unwrap() = Some(pairing_file);
    // A new pairing file invalidates any cached tunnel built from the previous
    // credentials, so drop it and force the next request to reconnect.
    *rsd_connection_slot().lock().unwrap() = None;
    Ok(())
}

pub async fn connect_to_rsd_services<Service: RsdService>() -> Result<Service, IdeviceError> {
    // Try to reuse the cached tunnel first.
    {
        let mut guard = rsd_connection_slot().lock().unwrap();
        if let Some(conn) = guard.as_mut() {
            match Service::connect_rsd(&mut conn.adapter, &mut conn.handshake).await {
                Ok(r) => {
                    info!("using existing connection");
                    return Ok(r);
                }
                Err(e) => {
                    // Any failure on a cached connection means it is no longer
                    // usable; discard it and rebuild a fresh tunnel below.
                    info!("cached connection failed ({e}), rebuilding");
                    *guard = None;
                }
            }
        }
    }

    let conn = create_rppairing_rsd_connection().await?;
    info!("creating new connection");
    let mut guard = rsd_connection_slot().lock().unwrap();
    *guard = Some(conn);
    let conn = guard.as_mut().unwrap();
    Service::connect_rsd(&mut conn.adapter, &mut conn.handshake).await
}

pub async fn get_or_create_rppairing_rsd_connection(
) -> Result<std::sync::MutexGuard<'static, Option<CachedRsdConnection>>, IdeviceError> {
    let mut guard = rsd_connection_slot().lock().unwrap();
    let cached_ok = if let Some(conn) = guard.as_mut() {
        HeartbeatClient::connect_rsd(&mut conn.adapter, &mut conn.handshake)
            .await
            .is_ok()
    } else {
        false
    };
    if cached_ok {
        info!("using existing connection");
        return Ok(guard);
    }

    // Cached connection is missing or dead — rebuild it without holding the lock
    // across the (slow) connection setup.
    *guard = None;
    drop(guard);

    let conn = create_rppairing_rsd_connection().await?;
    info!("creating new connection");
    let mut guard = rsd_connection_slot().lock().unwrap();
    *guard = Some(conn);
    Ok(guard)
}

async fn create_rppairing_rsd_connection() -> Result<CachedRsdConnection, IdeviceError> {
    let mut pairing_file = match rppairing_file_slot().lock().unwrap().clone() {
        Some(p) => p,
        None => {
            error!("No PairingFile");
            return Err(IdeviceError::UserDeniedPairing);
        }
    };

    let socket_addr = SocketAddrV4::from_str("10.7.0.1:49152").unwrap();
    let stream = match tokio::net::TcpStream::connect(socket_addr).await {
        Ok(s) => s,
        Err(e) => {
            return Err(IdeviceError::Socket(e));
        }
    };

    let conn = RpPairingSocket::new(stream);

    let mut rpc = RemotePairingClient::new(conn, &"minimuxer", &mut pairing_file);
    rpc.connect(async |_| "000000".to_string(), 0u8).await?;

    use idevice::remote_pairing::connect_tls_psk_tunnel_native;

    let tunnel_port = rpc.create_tcp_listener().await?;

    let tunnel_addr =
        std::net::SocketAddr::new(std::net::IpAddr::V4(*socket_addr.ip()), tunnel_port);
    let tunnel_stream = tokio::net::TcpStream::connect(tunnel_addr).await?;
    let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, rpc.encryption_key()).await?;
    let client_ip: std::net::IpAddr = tunnel
        .info
        .client_address
        .parse()
        .map_err(|e| IdeviceError::AddrParseError(e))?;
    let server_ip: std::net::IpAddr = tunnel
        .info
        .server_address
        .parse()
        .map_err(|e| IdeviceError::AddrParseError(e))?;
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;

    let raw = tunnel.into_inner();
    let mut adapter = idevice::tcp::adapter::Adapter::new(Box::new(raw), client_ip, server_ip);
    adapter.set_mss(mtu.saturating_sub(60));
    let mut adapter = adapter.to_async_handle();

    let rsd_stream = adapter.connect(rsd_port).await?;
    let handshake = RsdHandshake::new(rsd_stream).await?;

    Ok(CachedRsdConnection { adapter, handshake })
}
