# Resource recommendation

## Original production profile

Paste under the RabbitMQ Cluster Operator `spec` field:

```yaml
rabbitmq:
  additionalConfig: |
    vm_memory_high_watermark.absolute = 20Gi
resources:
  requests:
    cpu: 1
    memory: 24Gi
  limits:
    cpu: 1
    memory: 24Gi
```

## KinD test profile

```yaml
rabbitmq:
  additionalConfig: |
    vm_memory_high_watermark.absolute = 1Gi
resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: 1
    memory: 2Gi
```
