/* One arm of the glib-networking verification described in QEMU-TEST-PLAN.md §5b.
 *
 *     tls-verify <host> <port>
 *
 * WHY THIS EXISTS RATHER THAN A curl INVOCATION. The thing under test is the
 * GTlsBackend that glib-networking installs -- the path libsoup uses, and
 * therefore the path gnome-software's certificate checking runs through. curl
 * links libcrypto directly and verifies by its own means; so does
 * `openssl s_client`. Either would pass with a completely broken
 * glib-networking, which makes them well-formed answers to a different
 * question.
 *
 * GSocketClient with TLS enabled obtains a GTlsClientConnection from the
 * INSTALLED backend. That is the whole reason for the forty lines.
 *
 * WHAT IT REPORTS, AND WHY THREE OUTCOMES RATHER THAN TWO:
 *
 *     0  CONNECTED     the TLS handshake completed and the certificate was
 *                      accepted
 *     1  REJECTED      the peer's certificate was refused -- this is the
 *                      SUCCESS condition for the three negative arms
 *     2  CANNOT-TEST   no TLS backend, DNS failure, connection refused, or
 *                      anything else that is not a verdict about a certificate
 *
 * 1 and 2 are both "did not connect", and collapsing them would be the defect
 * this whole test exists to catch. A missing glib-networking makes every arm
 * fail; three negative arms failing then looks exactly like a pass, and the
 * positive arm failing is the only thing that distinguishes them. Reporting
 * CANNOT-TEST separately means that case names itself instead of hiding inside
 * a row of expected rejections.
 */

#include <gio/gio.h>
#include <stdio.h>
#include <stdlib.h>

int
main (int argc, char *argv[])
{
	if (argc != 3) {
		fprintf (stderr, "usage: tls-verify <host> <port>\n");
		return 2;
	}

	const char *host = argv[1];
	int port = atoi (argv[2]);

	/* Asked before connecting, because "there is no TLS backend" is a fact
	 * about this system rather than about the peer, and it must not arrive
	 * disguised as a handshake failure. Without glib-networking installed,
	 * GLib supplies a backend that supports nothing rather than failing to
	 * return one -- so the question is what it supports, not whether it
	 * exists. */
	GTlsBackend *backend = g_tls_backend_get_default ();
	if (backend == NULL || !g_tls_backend_supports_tls (backend)) {
		printf ("CANNOT-TEST  no TLS backend supports TLS on this system.\n");
		printf ("             glib-networking is not installed, or its module\n");
		printf ("             directory is not where GIO looks. Every arm of\n");
		printf ("             this test would 'fail' and the three negative\n");
		printf ("             ones would look like passes.\n");
		return 2;
	}

	g_autoptr (GSocketClient) client = g_socket_client_new ();

	/* Default validation, deliberately. There is a
	 * g_socket_client_set_tls_validation_flags() and it is exactly what must
	 * NOT be touched here: relaxing the flags would make every negative arm
	 * connect and the test would report a verifying backend on a system that
	 * verifies nothing. */
	g_socket_client_set_tls (client, TRUE);

	g_autoptr (GError) error = NULL;
	g_autoptr (GSocketConnection) connection =
		g_socket_client_connect_to_host (client, host, (guint16) port, NULL, &error);

	if (connection != NULL) {
		printf ("CONNECTED    %s:%d — certificate ACCEPTED\n", host, port);
		return 0;
	}

	/* A certificate verdict, and only that, is a REJECTED. Everything else --
	 * refused connection, unknown host, timeout -- is a failure to test rather
	 * than evidence about verification, and saying so is the point. */
	if (g_error_matches (error, G_TLS_ERROR, G_TLS_ERROR_BAD_CERTIFICATE) ||
	    g_error_matches (error, G_TLS_ERROR, G_TLS_ERROR_CERTIFICATE_REQUIRED) ||
	    g_error_matches (error, G_TLS_ERROR, G_TLS_ERROR_HANDSHAKE)) {
		printf ("REJECTED     %s:%d — %s\n", host, port, error->message);
		return 1;
	}

	printf ("CANNOT-TEST  %s:%d — %s\n", host, port, error->message);
	printf ("             Not a verdict about a certificate: the connection\n");
	printf ("             never got far enough to produce one.\n");
	return 2;
}
