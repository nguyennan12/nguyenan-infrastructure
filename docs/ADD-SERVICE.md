# Adding an infrastructure service

Phase 3 uses two small JSON registries and trusted Bash adapters. Registration describes a service; it does not deploy, enable or initialize it automatically.

## Lifecycle states

- **Registered**: metadata exists and passes registry validation.
- **Enabled**: `enabled: true` permits orchestration to consider the stack or service.
- **Deployed**: the registered containers exist on the current host.
- **Available**: the service adapter confirms project provisioning can use it.
- **Healthy**: the adapter's read-only health hook succeeds.

An optional stack should normally be committed with `enabled: false`, validated in CI, configured on the target host, and enabled only through a reviewed change.

## 1. Create the Compose stack

Add one Compose file under `stacks/`. Reuse the external `proxy` network only when ingress is needed. Declare explicit container names and stable named volumes. Do not duplicate an existing stack definition or embed credentials.

For a generic service, Standalone deployment supports the `generic` handler with `container-running` readiness. A service that needs custom initialization requires a reviewed, explicitly allowlisted handler; registry metadata cannot contain shell commands.

## 2. Register the stack

Add an entry to `registry/stacks.json` with a lowercase identifier, Compose file, project name, dependencies, resource names, required environment, secret file, lifecycle flags, handler and readiness type. Registry paths are repository-relative and must stay inside the trusted repository. Registration alone does not deploy the stack.

## 3. Implement the service adapter

Create `scripts/services/<service>/adapter.sh` and keep its provisioning implementation in `scripts/services/<service>/provision.sh`. A project-provisionable adapter implements:

```bash
service_validate_configuration
service_is_available
service_health
service_backup_available
service_provision
service_remove
service_generate_connection_config
```

The core initializes `PROJECT`, `PROJECT_DIR`, `ENV_FILE`, `MANIFEST` and conventional resource variables. Hooks receive no command strings from JSON. Validation, availability and health are read-only. Provision/remove update the manifest only after resource changes succeed. The caller owns locks. Hooks must not print credentials.

PostgreSQL, Redis and MinIO adapters wrap the existing modules rather than reimplementing them.

## 4. Register the project service

Add the service to `registry/services.json` with its stack, dependencies, capabilities, adapter and project environment keys. Dependencies must be registered and acyclic. A dependency must already be enabled for the project or selected in the same operation. Removal runs in reverse dependency order.

## 5. Define secrets

Declare only secret names, generators and the stack secret file. Supported generators are `password`, `literal` and `prompt-email`. Values remain under `/opt/infra/secrets` or in Dockhand and are never committed. Credential relationships such as PostgreSQL/PgBouncer and Redis backup authentication remain in trusted setup code.

## 6. Backup and restore handlers

Backup and restore handlers live beside the adapter as `scripts/services/<service>/backup.sh` and `restore.sh`. Registry destinations keep the installed names `/opt/infra/backup/backup-<service>.sh` and `/opt/infra/scripts/restore-<service>.sh`. Register the existing-compatible Restic tag, deterministic order and whether an unavailable enabled service must fail aggregate backup. Backup handlers honor `BACKUP_LOCK_HELD=1` to avoid recursive locking.

Restore handlers use an explicit phase: `before-service-start`, `after-database-start`, `after-service-start` or `final-verification`. `restore-all.sh` extracts snapshots in phase order but does not blindly start containers or import data.

## 7. Register managed files

List required files in `managed_files`. Destinations are restricted to:

```text
scripts/services/<service>/adapter.sh
scripts/services/<service>/provision.sh
scripts/services/<service>/backup.sh
scripts/services/<service>/restore.sh
backup/backup-*.sh
```

Synchronization validates every mapping, installs registered files atomically, installs runtime Compose copies, and writes registry metadata last. A failed install does not advance `last-sync-commit`.

## 8. Test the service

```bash
bash scripts/validation/validate-registry.sh
bash tests/run.sh
docker compose -f stacks/<service>.yml config --quiet
```

Test invalid paths, hooks, dependency cycles, disabled/unavailable behavior, provision/remove state, backup failures and restore phases. `tests/fixtures/extensibility` demonstrates a complete mock service without deployment.

## 9. Enable and deploy in Standalone mode

Keep a new optional stack disabled until configuration and recovery are reviewed. Then set `enabled: true`, run `setup-secrets.sh`, `deploy.sh --check`, and a manual `deploy.sh`. Generic stacks follow dependency order and wait for their registered containers.

No registry change switches an existing Dockhand host to Standalone ownership.

## 10. Register in Dockhand

GitOps does not create Dockhand stacks automatically. Register the same Compose file once with the exact `project_name`, environment and secrets. Configure deployment order operationally and verify readiness.

The installed `sync-infra.sh` does not update itself. Review and install a new sync script manually before expecting new registered files to synchronize.

## 11. Provision for a project

```bash
sudo /opt/infra/scripts/list-services.sh
sudo /opt/infra/scripts/create-project.sh example --services postgres,<service>
sudo /opt/infra/scripts/add-service.sh example --services <service>
```

Legacy `--postgres`, `--redis`, `--minio` and `--all` flags remain supported. Legacy projects are listed but are not migrated automatically.
