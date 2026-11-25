# External software licenses

The [MIT License](LICENSE) covers the original scripts, configuration, registries, tests, and documentation in this repository. It does **not** relicense software installed, downloaded, or run by these scripts. Check the license for each exact upstream version and image before distribution or commercial use.

| Component | Upstream license reference |
|---|---|
| Docker Engine | [Apache-2.0](https://github.com/moby/moby/blob/master/LICENSE) |
| PostgreSQL | [PostgreSQL License](https://www.postgresql.org/about/licence/) |
| Redis 8 | [RSALv2, SSPLv1, or AGPLv3](https://redis.io/legal/licenses/) |
| MinIO community server | [AGPLv3; review the image and its upstream status](https://github.com/minio/minio/blob/master/LICENSE) |
| Traefik | [MIT](https://github.com/traefik/traefik/blob/master/LICENSE.md) |
| PgBouncer | [ISC](https://github.com/pgbouncer/pgbouncer/blob/master/COPYRIGHT) |
| Restic | [BSD-2-Clause](https://github.com/restic/restic/blob/master/LICENSE) |
| Rclone | [MIT](https://github.com/rclone/rclone/blob/master/COPYING) |
| Dockhand v1.0.59 (installer default) | [Business Source License 1.1 with separate commercial terms](https://github.com/Finsys/dockhand/blob/v1.0.59/LICENSE.md) |

Dockhand's current upstream terms restrict some production uses, including business use without a commercial license. GitOps operators must review those terms for their use case. The repository does not bundle these programs; the MinIO and PgBouncer images are published by third parties and may include additional licensed components. Ubuntu packages and container image layers also have their own terms. The referenced licenses can change across versions, particularly where image tags are mutable.
