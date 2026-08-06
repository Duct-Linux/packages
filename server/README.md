# Serving the Duct repository

The repository is a directory of static files. Any web server can serve it;
`Caddyfile` here is the reference configuration.

## Layout on the server

```
/srv/duct/repo/
├── repo.db          SQLite index, rewritten on every publish
├── repo.db.sig      detached ed25519 signature over repo.db
└── packages/        <name>-<version>-<subversion>.<arch>.tape.tar.gz
```

Nothing else is needed. `repo.db` and `repo.db.sig` sit at the root; packages
live one level down under `packages/`. That split is not a convention — it is
where tape looks (`joinRepoLocation` and `joinPkgLocation`).

## Verifying a deployment

```sh
curl -sI https://repo.duct.dss-net.de/repo.db -H 'Accept-Encoding: gzip'
#   expect: content-encoding: gzip, cache-control: max-age=60

curl -sI https://repo.duct.dss-net.de/repo.db.sig
#   expect: cache-control: max-age=60  (same as the index -- see the Caddyfile)

curl -sI https://repo.duct.dss-net.de/packages/m4-1.4.20-1.aarch64.tape.tar.gz
#   expect: cache-control: immutable, and NO content-encoding
```

The compression rule is the one part worth actually checking rather than
trusting: it depends on the `header` directive setting the index's content type
before `encode` inspects it.

## The end-to-end test

Nothing above proves the repository works. This does:

```sh
docker run --rm ghcr.io/duct-linux/base:latest /usr/bin/tape install -y sed
```

That exercises the HTTPS fetch, signature verification against the trusted
public key, the sha256 of the downloaded package against the signed index, and
the install itself.

## Client setup

Two files on the client:

```sh
# 1. trust the repository's signing key
install -Dm644 duct.key.pub /etc/tape/keys/b52682f595163139.pub

# 2. point tape at the repository
install -Dm644 duct.toml /etc/tape/repos/duct.toml
```

The config filename matters. The signature is bound to the repository name via
`sign-repo --name duct`, and tape checks it against the config's key — which is
the filename minus its extension. Rename it to `mirror.toml` and verification
fails with a wrong-subject error, by design: it is what stops a signature being
lifted from one repository and replayed against another.

The public key's filename is only convention (the key id); lookup is by the id
derived from the key material itself, so a key file cannot claim an identity
that does not match its contents.
