//! Wire fixture for backend reset failure modes unavailable on stock PostgreSQL.
use super::Server;
use crate::config::{Address, User};
use crate::messages::simple_query;
use crate::stats::ServerStats;
use bytes::{BufMut, BytesMut};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

fn frame(code: u8, body: &[u8]) -> Vec<u8> {
    let mut result = vec![code];
    result.extend_from_slice(&((body.len() + 4) as i32).to_be_bytes());
    result.extend_from_slice(body);
    result
}

fn notice(code: &str) -> Vec<u8> {
    frame(
        b'N',
        format!("SNOTICE\0C{code}\0Mcommand without clusterwide effect\0\0").as_bytes(),
    )
}

async fn backend(
    reset: Option<&str>,
    exchanges: Vec<(u8, Vec<u8>)>,
) -> (Server, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let task = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let len = stream.read_i32().await.unwrap();
        let mut startup = vec![0; len as usize - 4];
        stream.read_exact(&mut startup).await.unwrap();
        let handshake = [frame(b'R', &0i32.to_be_bytes()), frame(b'Z', b"I")].concat();
        stream.write_all(&handshake).await.unwrap();
        for (code, response) in exchanges {
            assert_eq!(stream.read_u8().await.unwrap(), code);
            let len = stream.read_i32().await.unwrap();
            let mut query = vec![0; len as usize - 4];
            stream.read_exact(&mut query).await.unwrap();
            stream.write_all(&response).await.unwrap();
        }
        // Keep the socket open until the test drops Server, including a reset
        // cancellation test whose response intentionally has no ReadyForQuery.
        let mut tail = [0; 64];
        let _ = stream.read(&mut tail).await;
    });
    let server = Server::startup(
        &Address {
            port,
            ..Address::default()
        },
        &User::default(),
        "test",
        Arc::default(),
        Arc::new(ServerStats::default()),
        true,
        reset.map(str::to_owned),
        false,
        4,
        "reset-test".into(),
        true,
        &Default::default(),
        Arc::default(),
    )
    .await
    .unwrap();
    (server, task)
}

fn dirty(server: &mut Server) {
    server.mark_dirty();
    server
        .prepared_statement_cache
        .as_mut()
        .unwrap()
        .put("saved".into(), ());
    server
        .server_parameters
        .set_param("search_path", "client_schema", true);
}

#[tokio::test]
async fn custom_reset_drains_rows_and_notices_and_commits_only_at_idle() {
    let mut row = BytesMut::new();
    row.put_i16(1);
    row.put_i32(20_000);
    row.extend_from_slice(&vec![b'x'; 20_000]);
    let response = [
        frame(b'C', b"DEALLOCATE ALL\0"),
        notice("00000"),
        frame(b'D', &row),
        frame(b'C', b"SELECT 1\0"),
        frame(b'Z', b"I"),
    ]
    .concat();
    let (mut server, task) = backend(
        Some("full reset"),
        vec![(b'Q', response), (b'Q', frame(b'Z', b"I"))],
    )
    .await;
    dirty(&mut server);
    // Cleanup must ignore an old Flush response count and wait for Z.
    server.set_async_mode(true);
    server.set_expected_responses(0);
    server.checkin_cleanup().await.unwrap();
    assert!(!server.is_bad());
    assert!(!server.cleanup_state.needs_cleanup());
    assert!(server.prepared_statement_cache.as_ref().unwrap().is_empty());
    assert!(!server
        .server_parameters
        .as_hashmap()
        .contains_key("search_path"));
    server.small_simple_query("next client").await.unwrap();
    drop(server);
    task.await.unwrap();
}

#[tokio::test]
async fn failed_or_incomplete_resets_never_commit_cleanup_state() {
    let error = frame(b'E', b"SERROR\0C42601\0Munsupported reset\0\0");
    for failure in [
        [error, frame(b'Z', b"I")].concat(),
        [notice("0AM01"), frame(b'Z', b"I")].concat(),
        [notice("0A000"), frame(b'Z', b"I")].concat(),
        [frame(b'I', b""), frame(b'Z', b"I")].concat(),
        frame(b'G', &[0, 0, 0]),
        frame(b'Z', b"T"),
        frame(b'Z', b"E"),
    ] {
        let response = [frame(b'C', b"DEALLOCATE ALL\0"), failure].concat();
        let (mut server, task) = backend(Some("partial reset"), vec![(b'Q', response)]).await;
        dirty(&mut server);
        assert!(server.checkin_cleanup().await.is_err());
        assert!(server.is_bad());
        assert!(server.cleanup_state.needs_cleanup());
        assert_eq!(server.prepared_statement_cache.as_ref().unwrap().len(), 1);
        assert!(server
            .server_parameters
            .as_hashmap()
            .contains_key("search_path"));
        assert!(server.checkin_cleanup().await.is_err());
        drop(server);
        task.await.unwrap();
    }
}

#[tokio::test]
async fn cancelled_reset_retires_backend() {
    let (mut server, task) =
        backend(Some("slow reset"), vec![(b'Q', frame(b'C', b"RESET\0"))]).await;
    dirty(&mut server);
    assert!(tokio::time::timeout(
        std::time::Duration::from_millis(30),
        server.checkin_cleanup()
    )
    .await
    .is_err());
    assert!(server.is_bad());
    assert!(server.cleanup_state.needs_cleanup());
    drop(server);
    task.await.unwrap();
}

#[tokio::test]
async fn greengage_discard_invalidates_local_prepared_but_requires_cluster_reset() {
    for configured in [false, true] {
        let response = [
            notice("0AM01"),
            frame(b'C', b"DISCARD ALL\0"),
            frame(b'Z', b"I"),
        ]
        .concat();
        let mut exchanges = vec![(b'Q', response)];
        if configured {
            exchanges.push((b'Q', [frame(b'C', b"RESET\0"), frame(b'Z', b"I")].concat()));
        }
        let (mut server, task) = backend(configured.then_some("cluster reset"), exchanges).await;
        dirty(&mut server);
        server
            .send_and_flush(&simple_query("DISCARD ALL"))
            .await
            .unwrap();
        server.recv(&mut tokio::io::sink(), None).await.unwrap();
        assert!(server.prepared_statement_cache.as_ref().unwrap().is_empty());
        assert!(server.cleanup_state.needs_cleanup());
        assert_eq!(server.is_bad(), !configured);
        if configured {
            server.checkin_cleanup().await.unwrap();
            assert!(!server.cleanup_state.needs_cleanup());
        }
        drop(server);
        task.await.unwrap();
    }
}
