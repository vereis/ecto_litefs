# EctoLiteFS E2E Tests

End-to-end tests for EctoLiteFS using Docker and real LiteFS clusters.

## Prerequisites

- Docker and Docker Compose
- `curl` and `jq` for the test script

## Structure

```
e2e/
├── Dockerfile           # Multi-stage build for Elixir app with LiteFS
├── docker-compose.yml   # Primary + Replica cluster setup
├── config/
│   ├── litefs.primary.yml   # LiteFS config for primary node
│   └── litefs.replica.yml   # LiteFS config for replica node
├── test_app/            # Minimal Elixir app using EctoLiteFS
│   ├── lib/
│   │   └── test_app/
│   │       ├── application.ex
│   │       ├── repo.ex
│   │       └── router.ex
│   ├── config/
│   │   └── config.exs
│   └── mix.exs
├── run_tests.sh         # E2E test script
└── README.md
```

## Running Tests

```bash
cd e2e
./run_tests.sh
```

This will:
1. Build Docker images
2. Start a LiteFS cluster with primary and replica nodes
3. Run E2E tests verifying:
   - Cluster health
   - Write to primary, read from both
   - Write forwarding from replica to primary
4. Clean up containers

## Manual Testing

Start the cluster:
```bash
docker-compose up -d
```

Check status:
```bash
# Primary (port 4001)
curl http://localhost:4001/status

# Replica (port 4002)
curl http://localhost:4002/status
```

Create an item:
```bash
curl -X POST http://localhost:4001/items \
  -H "Content-Type: application/json" \
  -d '{"name": "test item"}'
```

List items:
```bash
curl http://localhost:4001/items
curl http://localhost:4002/items
```

Stop the cluster:
```bash
docker-compose down -v
```

## Debugging

View logs:
```bash
docker-compose logs -f primary
docker-compose logs -f replica
```

Shell into a container:
```bash
docker-compose exec primary /bin/bash
```

Check LiteFS mount:
```bash
docker-compose exec primary ls -la /litefs
docker-compose exec primary cat /litefs/.primary
```
