#!/bin/bash
set -euo pipefail
cd ~/rooscloset

echo "=== Writing CDK source files ==="

cat > cdk/bin/app.ts << 'EOF'
#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { SharedStack } from '../lib/shared-stack';
import { AtlasStack } from '../lib/atlas-stack';
import { MirrorStack } from '../lib/mirror-stack';

const app = new cdk.App();
const env = {
  account: process.env.CDK_DEFAULT_ACCOUNT,
  region: process.env.CDK_DEFAULT_REGION ?? 'us-west-2',
};

const shared = new SharedStack(app, 'RoosCloset-Shared', { env });
const atlas = new AtlasStack(app, 'RoosCloset-ATLAS', { env, shared });
const mirror = new MirrorStack(app, 'RoosCloset-MIRROR', { env, shared });
atlas.addDependency(shared);
mirror.addDependency(shared);

cdk.Tags.of(app).add('Project', 'RoosCloset');
cdk.Tags.of(atlas).add('Product', 'ATLAS');
cdk.Tags.of(mirror).add('Product', 'MIRROR');
app.synth();
EOF

cat > cdk/lib/shared-stack.ts << 'EOF'
import * as cdk from 'aws-cdk-lib';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as apigateway from 'aws-cdk-lib/aws-apigateway';
import * as logs from 'aws-cdk-lib/aws-logs';
import { Construct } from 'constructs';

export class SharedStack extends cdk.Stack {
  public readonly dataLake: s3.Bucket;
  public readonly userPool: cognito.UserPool;
  public readonly api: apigateway.RestApi;

  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    this.dataLake = new s3.Bucket(this, 'DataLake', {
      bucketName: `rooscloset-data-lake-${this.account}`,
      versioned: true,
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      lifecycleRules: [
        {
          prefix: 'raw/',
          transitions: [{
            storageClass: s3.StorageClass.INTELLIGENT_TIERING,
            transitionAfter: cdk.Duration.days(30)
          }]
        },
        { prefix: 'models/', expiration: cdk.Duration.days(90) },
      ],
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    this.userPool = new cognito.UserPool(this, 'UserPool', {
      userPoolName: 'rooscloset-tenants',
      selfSignUpEnabled: false,
      signInAliases: { email: true },
      passwordPolicy: {
        minLength: 12,
        requireLowercase: true,
        requireUppercase: true,
        requireDigits: true
      },
      accountRecovery: cognito.AccountRecovery.EMAIL_ONLY,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const resourceServer = new cognito.UserPoolResourceServer(this, 'ResourceServer', {
      userPool: this.userPool,
      identifier: 'rooscloset',
      scopes: [
        new cognito.ResourceServerScope({ scopeName: 'atlas', scopeDescription: 'ATLAS API' }),
        new cognito.ResourceServerScope({ scopeName: 'mirror', scopeDescription: 'MIRROR API' }),
      ],
    });

    new cognito.UserPoolClient(this, 'ApiClient', {
      userPool: this.userPool,
      generateSecret: true,
      authFlows: { adminUserPassword: true, userSrp: true },
      oAuth: {
        flows: { clientCredentials: true },
        scopes: [
          cognito.OAuthScope.resourceServer(
            resourceServer,
            new cognito.ResourceServerScope({ scopeName: 'atlas', scopeDescription: 'ATLAS API' })
          ),
          cognito.OAuthScope.resourceServer(
            resourceServer,
            new cognito.ResourceServerScope({ scopeName: 'mirror', scopeDescription: 'MIRROR API' })
          ),
        ],
      },
    });

    const logGroup = new logs.LogGroup(this, 'ApiLogs', {
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: cdk.RemovalPolicy.DESTROY
    });

    this.api = new apigateway.RestApi(this, 'Api', {
      restApiName: 'rooscloset-api',
      description: 'RoosCloset B2B Fashion Intelligence API',
      deployOptions: {
        stageName: 'v1',
        accessLogDestination: new apigateway.LogGroupLogDestination(logGroup),
        accessLogFormat: apigateway.AccessLogFormat.jsonWithStandardFields(),
        tracingEnabled: true,
        metricsEnabled: true,
        throttlingRateLimit: 100,
        throttlingBurstLimit: 200,
      },
      defaultCorsPreflightOptions: {
        allowOrigins: apigateway.Cors.ALL_ORIGINS,
        allowMethods: ['GET', 'POST', 'OPTIONS'],
      },
    });

    new cdk.CfnOutput(this, 'DataLakeBucket', { value: this.dataLake.bucketName });
    new cdk.CfnOutput(this, 'UserPoolId', { value: this.userPool.userPoolId });
    new cdk.CfnOutput(this, 'ApiEndpoint', { value: this.api.url });
  }
}
EOF

cat > cdk/lib/atlas-stack.ts << 'EOF'
import * as cdk from 'aws-cdk-lib';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as sfn from 'aws-cdk-lib/aws-stepfunctions';
import * as tasks from 'aws-cdk-lib/aws-stepfunctions-tasks';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as sqs from 'aws-cdk-lib/aws-sqs';
import * as s3n from 'aws-cdk-lib/aws-s3-notifications';
import * as lambdaEvents from 'aws-cdk-lib/aws-lambda-event-sources';
import * as apigateway from 'aws-cdk-lib/aws-apigateway';
import { Construct } from 'constructs';
import { SharedStack } from './shared-stack';

interface AtlasStackProps extends cdk.StackProps { shared: SharedStack; }

export class AtlasStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: AtlasStackProps) {
    super(scope, id, props);
    const { dataLake, api } = props.shared;

    const skuTable = new dynamodb.Table(this, 'SkuTable', {
      tableName: 'rooscloset-sku-attributes',
      partitionKey: { name: 'tenant_id', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'sku_id', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      pointInTimeRecovery: true,
      stream: dynamodb.StreamViewType.NEW_AND_OLD_IMAGES,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });
    skuTable.addGlobalSecondaryIndex({
      indexName: 'by-status',
      partitionKey: { name: 'tenant_id', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'processing_status', type: dynamodb.AttributeType.STRING },
    });

    const dlq = new sqs.Queue(this, 'DLQ', {
      retentionPeriod: cdk.Duration.days(14)
    });
    const ingestionQueue = new sqs.Queue(this, 'IngestionQueue', {
      visibilityTimeout: cdk.Duration.minutes(15),
      deadLetterQueue: { queue: dlq, maxReceiveCount: 3 },
    });
    dataLake.addEventNotification(
      s3.EventType.OBJECT_CREATED,
      new s3n.SqsDestination(ingestionQueue),
      { prefix: 'raw/', suffix: '.jpg' }
    );
    dataLake.addEventNotification(
      s3.EventType.OBJECT_CREATED,
      new s3n.SqsDestination(ingestionQueue),
      { prefix: 'raw/', suffix: '.png' }
    );

    const commonEnv = {
      SKU_TABLE: skuTable.tableName,
      DATA_LAKE_BUCKET: dataLake.bucketName,
    };

    const ingestFn = new lambda.Function(this, 'IngestFn', {
      functionName: 'atlas-ingest',
      runtime: lambda.Runtime.PYTHON_3_11,
      handler: 'ingest.handler',
      code: lambda.Code.fromAsset('../atlas/handlers'),
      timeout: cdk.Duration.minutes(3),
      memorySize: 512,
      environment: commonEnv,
    });

    const rekognitionFn = new lambda.Function(this, 'RekognitionFn', {
      functionName: 'atlas-rekognition',
      runtime: lambda.Runtime.PYTHON_3_11,
      handler: 'rekognition_detect.handler',
      code: lambda.Code.fromAsset('../atlas/handlers'),
      timeout: cdk.Duration.minutes(3),
      memorySize: 512,
      environment: commonEnv,
    });
    rekognitionFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['rekognition:DetectLabels', 'rekognition:DetectModerationLabels'],
      resources: ['*'],
    }));

    const embedFn = new lambda.Function(this, 'EmbedFn', {
      functionName: 'atlas-embed',
      runtime: lambda.Runtime.PYTHON_3_11,
      handler: 'embed.handler',
      code: lambda.Code.fromAsset('../atlas/handlers'),
      timeout: cdk.Duration.minutes(5),
      memorySize: 1024,
      environment: {
        ...commonEnv,
        SAGEMAKER_ENDPOINT_NAME: 'atlas-clip-vit-l14',
        USE_MOCK_ENDPOINT: 'true',
      },
    });
    embedFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['sagemaker:InvokeEndpoint'],
      resources: [
        `arn:aws:sagemaker:${this.region}:${this.account}:endpoint/atlas-clip-vit-l14`
      ],
    }));

    const attributeFn = new lambda.Function(this, 'AttributeFn', {
      functionName: 'atlas-attribute',
      runtime: lambda.Runtime.PYTHON_3_11,
      handler: 'attribute.handler',
      code: lambda.Code.fromAsset('../atlas/handlers'),
      timeout: cdk.Duration.minutes(5),
      memorySize: 512,
      environment: {
        ...commonEnv,
        BEDROCK_MODEL_ID: 'HAIKU_ARN_PLACEHOLDER',
      },
    });
    attributeFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['bedrock:InvokeModel'],
      resources: ['*'],
    }));

    const indexFn = new lambda.Function(this, 'IndexFn', {
      functionName: 'atlas-index',
      runtime: lambda.Runtime.PYTHON_3_11,
      handler: 'index_handler.handler',
      code: lambda.Code.fromAsset('../atlas/handlers'),
      timeout: cdk.Duration.minutes(3),
      memorySize: 512,
      environment: {
        ...commonEnv,
        USE_MOCK_OPENSEARCH: 'true',
      },
    });

    [ingestFn, rekognitionFn, embedFn, attributeFn, indexFn].forEach(fn => {
      skuTable.grantReadWriteData(fn);
      dataLake.grantReadWrite(fn);
    });

    const failState = new sfn.Fail(this, 'PipelineFailed', { error: 'AtlasPipelineError' });
    const succeedState = new sfn.Succeed(this, 'PipelineComplete');

    const chain = new tasks.LambdaInvoke(this, 'Rekognition', {
      lambdaFunction: rekognitionFn, outputPath: '$.Payload',
    }).addCatch(failState, { resultPath: '$.error' })
    .next(new tasks.LambdaInvoke(this, 'Embed', {
      lambdaFunction: embedFn, outputPath: '$.Payload',
    }).addCatch(failState, { resultPath: '$.error' }))
    .next(new tasks.LambdaInvoke(this, 'Attribute', {
      lambdaFunction: attributeFn, outputPath: '$.Payload',
    }).addCatch(failState, { resultPath: '$.error' }))
    .next(new tasks.LambdaInvoke(this, 'Index', {
      lambdaFunction: indexFn, outputPath: '$.Payload',
    }).addCatch(failState, { resultPath: '$.error' }))
    .next(succeedState);

    const pipeline = new sfn.StateMachine(this, 'Pipeline', {
      stateMachineName: 'atlas-catalog-pipeline',
      definitionBody: sfn.DefinitionBody.fromChainable(chain),
      timeout: cdk.Duration.minutes(30),
      tracingEnabled: true,
    });

    ingestFn.addEnvironment('STATE_MACHINE_ARN', pipeline.stateMachineArn);
    pipeline.grantStartExecution(ingestFn);
    ingestFn.addEventSource(new lambdaEvents.SqsEventSource(ingestionQueue, { batchSize: 5 }));

    const atlasResource = api.root.addResource('atlas');
    atlasResource.addResource('ingest').addMethod('POST',
      new apigateway.LambdaIntegration(ingestFn));
    atlasResource.addResource('products').addResource('{sku_id}').addMethod('GET',
      new apigateway.LambdaIntegration(indexFn));
    atlasResource.addResource('search').addMethod('POST',
      new apigateway.LambdaIntegration(indexFn));

    new cdk.CfnOutput(this, 'SkuTableName', { value: skuTable.tableName });
    new cdk.CfnOutput(this, 'PipelineArn', { value: pipeline.stateMachineArn });
  }
}
EOF

cat > cdk/lib/mirror-stack.ts << 'EOF'
import * as cdk from 'aws-cdk-lib';
import * as kinesis from 'aws-cdk-lib/aws-kinesis';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as lambdaEvents from 'aws-cdk-lib/aws-lambda-event-sources';
import * as eventbridge from 'aws-cdk-lib/aws-events';
import * as targets from 'aws-cdk-lib/aws-events-targets';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as apigateway from 'aws-cdk-lib/aws-apigateway';
import { Construct } from 'constructs';
import { SharedStack } from './shared-stack';

interface MirrorStackProps extends cdk.StackProps { shared: SharedStack; }

export class MirrorStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: MirrorStackProps) {
    super(scope, id, props);
    const { dataLake, api } = props.shared;

    const orderStream = new kinesis.Stream(this, 'OrderStream', {
      streamName: 'rooscloset-order-events',
      shardCount: 1,
      retentionPeriod: cdk.Duration.days(3),
      encryption: kinesis.StreamEncryption.MANAGED,
    });

    const returnTable = new dynamodb.Table(this, 'ReturnTable', {
      tableName: 'rooscloset-return-events',
      partitionKey: { name: 'tenant_id', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'order_id', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      pointInTimeRecovery: true,
      timeToLiveAttribute: 'ttl',
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });
    returnTable.addGlobalSecondaryIndex({
      indexName: 'by-risk-score',
      partitionKey: { name: 'tenant_id', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'risk_score', type: dynamodb.AttributeType.NUMBER },
      projectionType: dynamodb.ProjectionType.ALL,
    });

    const interventionBus = new eventbridge.EventBus(this, 'InterventionBus', {
      eventBusName: 'rooscloset-interventions',
    });

    const scoreFn = new lambda.Function(this, 'ScoreFn', {
      functionName: 'mirror-score',
      runtime: lambda.Runtime.PYTHON_3_11,
      handler: 'score.handler',
      code: lambda.Code.fromAsset('../mirror/handlers'),
      timeout: cdk.Duration.seconds(10),
      memorySize: 512,
      reservedConcurrentExecutions: 50,
      environment: {
        RETURN_TABLE: returnTable.tableName,
        ORDER_STREAM: orderStream.streamName,
        SAGEMAKER_ENDPOINT: 'mirror-return-xgboost',
        USE_MOCK_ENDPOINT: 'true',
        RISK_THRESHOLD_HIGH: '0.65',
        RISK_THRESHOLD_MEDIUM: '0.40',
        EVENT_BUS_NAME: interventionBus.eventBusName,
      },
    });
    scoreFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['sagemaker:InvokeEndpoint'],
      resources: [
        `arn:aws:sagemaker:${this.region}:${this.account}:endpoint/mirror-return-xgboost`
      ],
    }));
    scoreFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['events:PutEvents'],
      resources: [interventionBus.eventBusArn],
    }));
    returnTable.grantReadWriteData(scoreFn);
    orderStream.grantWrite(scoreFn);

    const explainFn = new lambda.Function(this, 'ExplainFn', {
      functionName: 'mirror-explain',
      runtime: lambda.Runtime.PYTHON_3_11,
      handler: 'explain.handler',
      code: lambda.Code.fromAsset('../mirror/handlers'),
      timeout: cdk.Duration.minutes(2),
      memorySize: 1024,
      environment: {
        RETURN_TABLE: returnTable.tableName,
        DATA_LAKE_BUCKET: dataLake.bucketName,
        BEDROCK_MODEL_ID: 'HAIKU_ARN_PLACEHOLDER',
        CAUSAL_GRAPH_S3_KEY: 'models/mirror/causal_graph_latest.pkl',
        EVENT_BUS_NAME: interventionBus.eventBusName,
      },
    });
    explainFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['bedrock:InvokeModel'],
      resources: ['*'],
    }));
    explainFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['events:PutEvents'],
      resources: [interventionBus.eventBusArn],
    }));
    returnTable.grantReadWriteData(explainFn);
    dataLake.grantRead(explainFn);

    explainFn.addEventSource(new lambdaEvents.KinesisEventSource(orderStream, {
      startingPosition: lambda.StartingPosition.LATEST,
      batchSize: 10,
      bisectBatchOnError: true,
      retryAttempts: 3,
    }));

    const prescribeFn = new lambda.Function(this, 'PrescribeFn', {
      functionName: 'mirror-prescribe',
      runtime: lambda.Runtime.PYTHON_3_11,
      handler: 'prescribe.handler',
      code: lambda.Code.fromAsset('../mirror/handlers'),
      timeout: cdk.Duration.minutes(3),
      memorySize: 512,
      environment: {
        RETURN_TABLE: returnTable.tableName,
        DATA_LAKE_BUCKET: dataLake.bucketName,
        BEDROCK_MODEL_ID: 'HAIKU_ARN_PLACEHOLDER',
      },
    });
    prescribeFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['bedrock:InvokeModel'],
      resources: ['*'],
    }));
    returnTable.grantReadWriteData(prescribeFn);
    dataLake.grantRead(prescribeFn);

    new eventbridge.Rule(this, 'HighRiskRule', {
      eventBus: interventionBus,
      eventPattern: {
        source: ['rooscloset.mirror'],
        detailType: ['ReturnRiskScored'],
        detail: { risk_level: ['HIGH'] }
      },
      targets: [new targets.LambdaFunction(explainFn)],
    });
    new eventbridge.Rule(this, 'CausalCompleteRule', {
      eventBus: interventionBus,
      eventPattern: {
        source: ['rooscloset.mirror'],
        detailType: ['CausalAttributionComplete']
      },
      targets: [new targets.LambdaFunction(prescribeFn)],
    });

    const mirrorResource = api.root.addResource('mirror');
    mirrorResource.addResource('score').addMethod('POST',
      new apigateway.LambdaIntegration(scoreFn));
    mirrorResource.addResource('interventions').addResource('{sku_id}').addMethod('GET',
      new apigateway.LambdaIntegration(prescribeFn));

    new cdk.CfnOutput(this, 'OrderStreamArn', { value: orderStream.streamArn });
    new cdk.CfnOutput(this, 'ReturnTableName', { value: returnTable.tableName });
    new cdk.CfnOutput(this, 'ScoreEndpoint', { value: `${api.url}mirror/score` });
    new cdk.CfnOutput(this, 'InterventionBusArn', { value: interventionBus.eventBusArn });
  }
}
EOF

echo "=== Writing Lambda handlers ==="

cat > atlas/handlers/ingest.py << 'EOF'
"""ATLAS Stage 0: SQS consumer -> validates -> starts Step Functions"""
import json
import os
import boto3
import urllib.parse
from datetime import datetime, timezone

sfn = boto3.client('stepfunctions')
dynamodb = boto3.resource('dynamodb')
s3 = boto3.client('s3')

SKU_TABLE = os.environ['SKU_TABLE']
DATA_LAKE_BUCKET = os.environ['DATA_LAKE_BUCKET']
STATE_MACHINE_ARN = os.environ.get('STATE_MACHINE_ARN', '')

table = dynamodb.Table(SKU_TABLE)


def handler(event, context):
    if 'httpMethod' in event:
        body = json.loads(event.get('body', '{}'))
        result = process_product(body)
        return {
            'statusCode': 200,
            'headers': {'Content-Type': 'application/json'},
            'body': json.dumps(result)
        }

    results = []
    for record in event.get('Records', []):
        body = json.loads(record['body'])
        for s3_record in body.get('Records', []):
            bucket = s3_record['s3']['bucket']['name']
            key = urllib.parse.unquote_plus(s3_record['s3']['object']['key'])
            results.append(process_s3_upload(bucket, key))
    return {'processed': len(results), 'results': results}


def process_s3_upload(bucket: str, key: str) -> dict:
    parts = key.split('/')
    if len(parts) < 4:
        return {'error': f'Invalid key structure: {key}'}
    tenant_id = parts[1]
    sku_id = parts[-1].rsplit('.', 1)[0]
    return process_product({
        'tenant_id': tenant_id,
        'sku_id': sku_id,
        'image_s3_key': key,
        'merchant_description': '',
        'source_bucket': bucket,
    })


def process_product(payload: dict) -> dict:
    tenant_id = payload['tenant_id']
    sku_id = payload['sku_id']

    table.put_item(Item={
        'tenant_id': tenant_id,
        'sku_id': sku_id,
        'processing_status': 'processing',
        'image_s3_key': payload.get('image_s3_key', ''),
        'merchant_description': payload.get('merchant_description', ''),
        'ingested_at': datetime.now(timezone.utc).isoformat(),
    })

    if STATE_MACHINE_ARN:
        execution = sfn.start_execution(
            stateMachineArn=STATE_MACHINE_ARN,
            name=f"{tenant_id}-{sku_id}-{int(datetime.now().timestamp())}",
            input=json.dumps(payload),
        )
        return {
            'status': 'pipeline_started',
            'execution_arn': execution['executionArn'],
            'sku_id': sku_id
        }

    return {'status': 'ingested', 'sku_id': sku_id}
EOF

cat > atlas/handlers/rekognition_detect.py << 'EOF'
"""ATLAS Stage 1: Rekognition garment detection"""
import json
import os
import boto3

rekognition = boto3.client('rekognition')
DATA_LAKE_BUCKET = os.environ['DATA_LAKE_BUCKET']


def handler(event, context):
    bucket = event.get('source_bucket', DATA_LAKE_BUCKET)
    image_s3_key = event['image_s3_key']

    response = rekognition.detect_labels(
        Image={'S3Object': {'Bucket': bucket, 'Name': image_s3_key}},
        MaxLabels=25,
        MinConfidence=70.0,
        Features=['GENERAL_LABELS'],
        Settings={'GeneralLabels': {'LabelInclusionFilters': [
            'Clothing', 'Dress', 'Shirt', 'Pants', 'Jacket', 'Skirt',
            'Shoe', 'Bag', 'Jewelry', 'Fashion', 'Person', 'Fabric',
        ]}}
    )

    labels = [
        {'Name': l['Name'], 'Confidence': round(l['Confidence'], 1)}
        for l in response.get('Labels', [])
    ]

    return {
        **event,
        'rekognition_labels': labels,
        'rekognition_label_count': len(labels),
    }
EOF

cat > atlas/handlers/embed.py << 'EOF'
"""ATLAS Stage 2: CLIP embedding via SageMaker or mock"""
import json
import os
import math
import hashlib
import boto3

s3 = boto3.client('s3')
sagemaker_runtime = boto3.client('sagemaker-runtime')

DATA_LAKE_BUCKET = os.environ['DATA_LAKE_BUCKET']
SAGEMAKER_ENDPOINT_NAME = os.environ.get('SAGEMAKER_ENDPOINT_NAME', 'atlas-clip-vit-l14')
USE_MOCK = os.environ.get('USE_MOCK_ENDPOINT', 'false') == 'true'


def handler(event, context):
    tenant_id = event['tenant_id']
    sku_id = event['sku_id']
    image_s3_key = event['image_s3_key']

    if USE_MOCK:
        seed = int(hashlib.md5(sku_id.encode()).hexdigest()[:8], 16)
        embedding = []
        for i in range(512):
            seed = (seed * 1664525 + 1013904223) & 0xFFFFFFFF
            val = (seed / 0xFFFFFFFF) * 2 - 1
            embedding.append(val)
        magnitude = math.sqrt(sum(x * x for x in embedding))
        embedding = [x / magnitude for x in embedding]
    else:
        import base64
        image_bytes = s3.get_object(
            Bucket=DATA_LAKE_BUCKET, Key=image_s3_key
        )['Body'].read()
        payload = json.dumps({
            'inputs': [{'image': base64.b64encode(image_bytes).decode()}]
        })
        response = sagemaker_runtime.invoke_endpoint(
            EndpointName=SAGEMAKER_ENDPOINT_NAME,
            ContentType='application/json',
            Body=payload,
        )
        result = json.loads(response['Body'].read())
        embedding = (
            result[0] if isinstance(result, list)
            else result.get('embedding', [0.0] * 512)
        )

    embedding_key = f"processed/{tenant_id}/embeddings/{sku_id}.json"
    s3.put_object(
        Bucket=DATA_LAKE_BUCKET,
        Key=embedding_key,
        Body=json.dumps({'sku_id': sku_id, 'embedding': embedding, 'dim': len(embedding)}),
        ContentType='application/json',
    )

    return {
        **event,
        'clip_embedding_s3_key': embedding_key,
        'embedding_dim': len(embedding),
    }
EOF

cat > atlas/handlers/attribute.py << 'EOF'
"""ATLAS Stage 3: Bedrock Claude multimodal attribute extraction"""
import json
import os
import base64
import re
import boto3
from datetime import datetime, timezone

bedrock = boto3.client('bedrock-runtime')
dynamodb = boto3.resource('dynamodb')
s3 = boto3.client('s3')

SKU_TABLE = os.environ['SKU_TABLE']
DATA_LAKE_BUCKET = os.environ['DATA_LAKE_BUCKET']
BEDROCK_MODEL_ID = os.environ['BEDROCK_MODEL_ID']
table = dynamodb.Table(SKU_TABLE)

ATTRIBUTE_PROMPT = """You are a fashion product intelligence system. Analyze this product image and context, then extract attributes as JSON.

Merchant description: {merchant_description}
Rekognition labels: {rekognition_labels}

Return ONLY valid JSON with these fields:
{{
  "garment_type": "string",
  "silhouette": "string",
  "neckline": "string",
  "sleeve_length": "none|sleeveless|short|3/4|long",
  "fit": "slim|regular|relaxed|oversized|tailored",
  "fabric_family": "string",
  "primary_color": "string",
  "color_family": "string",
  "print_pattern": "solid|stripe|check|floral|abstract|geometric|animal|none",
  "occasion_primary": "casual|work|evening|activewear|occasion|beach|lounge",
  "occasion_stack": ["array of up to 3"],
  "season_affinity": ["spring","summer","fall","winter"],
  "formality_score": 0.0,
  "trend_alignment": {{"quiet_luxury": 0.0, "minimalist": 0.0, "streetwear": 0.0, "boho": 0.0}},
  "style_notes": "1-2 sentence consumer description",
  "search_keywords": ["10-15 keywords"],
  "pdp_copy_headline": "max 8 words",
  "pdp_copy_description": "2-3 sentences",
  "return_risk_flags": {{
    "color_photography_mismatch_risk": "low|medium|high",
    "size_ambiguity_risk": "low|medium|high",
    "fabric_hand_unclear": false,
    "needs_size_chart": false
  }},
  "extraction_confidence": 0.0
}}"""


def handler(event, context):
    tenant_id = event['tenant_id']
    sku_id = event['sku_id']
    image_s3_key = event['image_s3_key']
    merchant_description = event.get('merchant_description', '')
    rekognition_labels = event.get('rekognition_labels', [])

    image_obj = s3.get_object(Bucket=DATA_LAKE_BUCKET, Key=image_s3_key)
    image_bytes = image_obj['Body'].read()
    image_b64 = base64.standard_b64encode(image_bytes).decode('utf-8')
    ext = image_s3_key.rsplit('.', 1)[-1].lower()
    media_type = 'image/jpeg' if ext in ('jpg', 'jpeg') else f'image/{ext}'

    label_str = ', '.join([
        f"{l['Name']} ({l['Confidence']}%)" for l in rekognition_labels[:10]
    ])
    prompt = ATTRIBUTE_PROMPT.format(
        merchant_description=merchant_description or 'Not provided',
        rekognition_labels=label_str or 'None',
    )

    response = bedrock.invoke_model(
        modelId=BEDROCK_MODEL_ID,
        contentType='application/json',
        accept='application/json',
        body=json.dumps({
            'anthropic_version': 'bedrock-2023-05-31',
            'max_tokens': 2048,
            'temperature': 0.1,
            'messages': [{
                'role': 'user',
                'content': [
                    {
                        'type': 'image',
                        'source': {
                            'type': 'base64',
                            'media_type': media_type,
                            'data': image_b64
                        }
                    },
                    {'type': 'text', 'text': prompt},
                ],
            }],
        }),
    )

    response_body = json.loads(response['body'].read())
    raw_text = response_body['content'][0]['text'].strip()

    try:
        attributes = json.loads(raw_text)
    except json.JSONDecodeError:
        match = re.search(r'\{.*\}', raw_text, re.DOTALL)
        attributes = json.loads(match.group()) if match else {
            'extraction_confidence': 0.0,
            'extraction_notes': 'Parse failed'
        }

    attributes['_meta'] = {
        'tenant_id': tenant_id,
        'sku_id': sku_id,
        'extracted_at': datetime.now(timezone.utc).isoformat(),
        'model_id': BEDROCK_MODEL_ID,
    }

    attr_key = f'processed/{tenant_id}/attributes/{sku_id}.json'
    s3.put_object(
        Bucket=DATA_LAKE_BUCKET,
        Key=attr_key,
        Body=json.dumps(attributes),
        ContentType='application/json'
    )

    table.update_item(
        Key={'tenant_id': tenant_id, 'sku_id': sku_id},
        UpdateExpression=(
            "SET processing_status=:s, attributes_s3_key=:k, "
            "garment_type=:g, return_risk_flags=:r, extraction_confidence=:c"
        ),
        ExpressionAttributeValues={
            ':s': 'attributes_complete',
            ':k': attr_key,
            ':g': attributes.get('garment_type', 'unknown'),
            ':r': attributes.get('return_risk_flags', {}),
            ':c': str(attributes.get('extraction_confidence', 0)),
        },
    )

    return {
        **event,
        'attributes_s3_key': attr_key,
        'extraction_confidence': attributes.get('extraction_confidence', 0)
    }
EOF

cat > atlas/handlers/index_handler.py << 'EOF'
"""ATLAS Stage 4: Index to OpenSearch (mock for dev)"""
import json
import os
import boto3

dynamodb = boto3.resource('dynamodb')
SKU_TABLE = os.environ['SKU_TABLE']
USE_MOCK = os.environ.get('USE_MOCK_OPENSEARCH', 'false') == 'true'
table = dynamodb.Table(SKU_TABLE)


def handler(event, context):
    if 'httpMethod' in event:
        method = event['httpMethod']
        if method == 'GET':
            items = table.query(
                IndexName='by-status',
                KeyConditionExpression='tenant_id = :t',
                ExpressionAttributeValues={':t': 'test-tenant'},
                Limit=10,
            )
            return {
                'statusCode': 200,
                'body': json.dumps(
                    {'items': items.get('Items', [])}, default=str
                )
            }
        if method == 'POST':
            body = json.loads(event.get('body', '{}'))
            return {
                'statusCode': 200,
                'body': json.dumps({
                    'results': [],
                    'query': body,
                    'note': 'OpenSearch not yet connected'
                })
            }

    tenant_id = event['tenant_id']
    sku_id = event['sku_id']

    if USE_MOCK:
        table.update_item(
            Key={'tenant_id': tenant_id, 'sku_id': sku_id},
            UpdateExpression="SET processing_status=:s",
            ExpressionAttributeValues={':s': 'complete'},
        )
        return {**event, 'index_status': 'mock_indexed'}

    return {**event, 'index_status': 'indexed'}
EOF

cat > mirror/handlers/score.py << 'EOF'
"""MIRROR: Real-time return risk scorer. <150ms target."""
import json
import os
import time
import boto3
from datetime import datetime, timezone
from decimal import Decimal

sagemaker_runtime = boto3.client('sagemaker-runtime')
dynamodb = boto3.resource('dynamodb')
kinesis = boto3.client('kinesis')
eventbridge = boto3.client('events')

RETURN_TABLE = os.environ['RETURN_TABLE']
ORDER_STREAM = os.environ['ORDER_STREAM']
SAGEMAKER_ENDPOINT = os.environ.get('SAGEMAKER_ENDPOINT', 'mirror-return-xgboost')
USE_MOCK = os.environ.get('USE_MOCK_ENDPOINT', 'false') == 'true'
RISK_THRESHOLD_HIGH = float(os.environ.get('RISK_THRESHOLD_HIGH', '0.65'))
RISK_THRESHOLD_MEDIUM = float(os.environ.get('RISK_THRESHOLD_MEDIUM', '0.40'))
EVENT_BUS_NAME = os.environ.get('EVENT_BUS_NAME', 'rooscloset-interventions')
table = dynamodb.Table(RETURN_TABLE)


def build_feature_vector(order: dict) -> list:
    items = order.get('items', [])
    customer = order.get('customer', {})
    first_item = items[0] if items else {}

    def f(d, k, default=0):
        return float(d.get(k, default))

    sizing = [
        f(first_item, 'size_chart_present'),
        f(first_item, 'model_measurements_present'),
        f(first_item, 'multiple_fit_images'),
        f(first_item, 'customer_provided_measurements'),
        f(first_item, 'size_ambiguity_risk_score', 0.5),
        float(len(items)),
        float(sum(1 for i in items if i.get('category') == 'dress')),
        float(sum(1 for i in items if i.get('category') == 'pants')),
        float(sum(1 for i in items if i.get('category') == 'outerwear')),
        f(first_item, 'is_new_size_for_customer'),
    ]
    sizing.extend([0.0] * (50 - len(sizing)))

    content = [
        f(first_item, 'image_count', 1) / 10.0,
        f(first_item, 'has_lifestyle_photo'),
        f(first_item, 'has_detail_shot'),
        f(first_item, 'description_word_count', 50) / 500.0,
        f(first_item, 'color_photography_mismatch_risk', 0.5),
        f(first_item, 'fabric_hand_unclear'),
        f(first_item, 'attribute_extraction_confidence', 0.5),
        f(first_item, 'is_new_product'),
        f(first_item, 'days_since_product_launch', 30) / 365.0,
        f(first_item, 'sku_level_return_rate_30d'),
    ]
    content.extend([0.0] * (50 - len(content)))

    history = [
        f(customer, 'lifetime_orders') / 100.0,
        f(customer, 'lifetime_return_rate'),
        f(customer, 'returns_last_90d'),
        f(customer, 'orders_last_90d'),
        f(customer, 'is_first_order', 1),
        f(customer, 'days_since_last_order', 999) / 365.0,
        f(customer, 'account_age_days') / 730.0,
        f(customer, 'wishlist_items_purchased_pct'),
        f(customer, 'has_provided_style_profile'),
        f(customer, 'style_drift_velocity'),
    ]
    history.extend([0.0] * (50 - len(history)))

    hour = datetime.now(timezone.utc).hour
    ctx = [
        f(order, 'total_value') / 500.0,
        f(order, 'discount_pct'),
        f(order, 'is_sale_item'),
        float(order.get('shipping_method') == 'express'),
        float(hour) / 24.0,
        float(datetime.now(timezone.utc).weekday()) / 7.0,
        f(order, 'items_browsed_before_purchase', 1) / 20.0,
        f(order, 'time_on_pdp_seconds', 30) / 300.0,
        f(order, 'used_search'),
        f(order, 'used_recommendation'),
    ]
    ctx.extend([0.0] * (50 - len(ctx)))

    return sizing + content + history + ctx


def handler(event, context):
    start_time = time.time()

    body = event.get('body', '{}')
    order = json.loads(body) if isinstance(body, str) else body

    tenant_id = order.get('tenant_id')
    order_id = order.get('order_id')

    if not tenant_id or not order_id:
        return {
            'statusCode': 400,
            'body': json.dumps({'error': 'tenant_id and order_id required'})
        }

    features = build_feature_vector(order)

    if USE_MOCK:
        risk_score = 0.3
        if features[0] < 0.5:
            risk_score += 0.2
        if features[100] < 0.05:
            risk_score += 0.15
        if features[4] > 0.6:
            risk_score += 0.1
        risk_score = min(risk_score, 0.95)
    else:
        feature_csv = ','.join(str(x) for x in features)
        sm_response = sagemaker_runtime.invoke_endpoint(
            EndpointName=SAGEMAKER_ENDPOINT,
            ContentType='text/csv',
            Body=feature_csv,
        )
        risk_score = float(sm_response['Body'].read().decode().strip())

    if risk_score >= RISK_THRESHOLD_HIGH:
        risk_level, action = 'HIGH', 'show_size_chart_modal'
    elif risk_score >= RISK_THRESHOLD_MEDIUM:
        risk_level, action = 'MEDIUM', 'show_fit_guidance'
    else:
        risk_level, action = 'LOW', 'none'

    top_risk_factors = []
    if features[0] < 0.5:
        top_risk_factors.append('no_size_chart')
    if features[4] > 0.6:
        top_risk_factors.append('high_size_ambiguity')
    if features[100] < 0.05:
        top_risk_factors.append('new_customer')

    latency_ms = round((time.time() - start_time) * 1000)

    result = {
        'order_id': order_id,
        'tenant_id': tenant_id,
        'return_risk_score': round(risk_score, 4),
        'risk_level': risk_level,
        'top_risk_factors': top_risk_factors[:3],
        'recommended_action': action,
        'latency_ms': latency_ms,
        'scored_at': datetime.now(timezone.utc).isoformat(),
    }

    try:
        table.put_item(Item={
            'tenant_id': tenant_id,
            'order_id': order_id,
            'risk_score': Decimal(str(round(risk_score, 4))),
            'risk_level': risk_level,
            'top_risk_factors': top_risk_factors,
            'scored_at': datetime.now(timezone.utc).isoformat(),
            'ttl': int(time.time()) + (365 * 24 * 3600 * 2),
        })
    except Exception:
        pass

    if risk_level == 'HIGH':
        try:
            kinesis.put_record(
                StreamName=ORDER_STREAM,
                PartitionKey=tenant_id,
                Data=json.dumps({
                    'event_type': 'high_risk_order_scored',
                    'tenant_id': tenant_id,
                    'order_id': order_id,
                    'risk_score': risk_score
                }),
            )
            eventbridge.put_events(Entries=[{
                'Source': 'rooscloset.mirror',
                'DetailType': 'ReturnRiskScored',
                'Detail': json.dumps({
                    'tenant_id': tenant_id,
                    'order_id': order_id,
                    'risk_level': risk_level,
                    'risk_score': risk_score
                }),
                'EventBusName': EVENT_BUS_NAME,
            }])
        except Exception:
            pass

    return {
        'statusCode': 200,
        'headers': {'Content-Type': 'application/json'},
        'body': json.dumps(result)
    }
EOF

cat > mirror/handlers/explain.py << 'EOF'
"""MIRROR: Causal attribution engine (async, post-score)"""
import json
import os
import base64
import boto3
from datetime import datetime, timezone

bedrock = boto3.client('bedrock-runtime')
dynamodb = boto3.resource('dynamodb')
eventbridge = boto3.client('events')

RETURN_TABLE = os.environ['RETURN_TABLE']
BEDROCK_MODEL_ID = os.environ['BEDROCK_MODEL_ID']
EVENT_BUS_NAME = os.environ.get('EVENT_BUS_NAME', 'rooscloset-interventions')
table = dynamodb.Table(RETURN_TABLE)


def handler(event, context):
    if 'Records' in event:
        results = []
        for record in event['Records']:
            if 'kinesis' in record:
                payload = json.loads(
                    base64.b64decode(record['kinesis']['data']).decode()
                )
                results.append(process_order(payload))
            elif 'detail' in record:
                results.append(process_order(record['detail']))
        return {'processed': len(results)}
    if 'detail' in event:
        return process_order(event['detail'])
    return process_order(event)


def process_order(payload: dict) -> dict:
    tenant_id = payload.get('tenant_id', 'unknown')
    order_id = payload.get('order_id', 'unknown')
    risk_score = payload.get('risk_score', 0.7)

    attributions = {
        'sizing': {
            'confidence': 0.78,
            'estimated_reduction': 0.12,
            'evidence': 'No size chart detected'
        },
        'content_quality': {
            'confidence': 0.61,
            'estimated_reduction': 0.08,
            'evidence': 'Photography mismatch risk flagged by ATLAS'
        },
    }

    try:
        prompt = (
            f"Write a 100-word merchandising brief for a fashion SKU with "
            f"{risk_score:.0%} return risk. Primary cause: sizing uncertainty "
            f"(no size chart). Secondary: photography color mismatch. "
            f"Recommend top 2 interventions ranked by ROI."
        )
        response = bedrock.invoke_model(
            modelId=BEDROCK_MODEL_ID,
            body=json.dumps({
                'anthropic_version': 'bedrock-2023-05-31',
                'max_tokens': 256,
                'temperature': 0.3,
                'messages': [{'role': 'user', 'content': prompt}],
            }),
        )
        brief = json.loads(response['body'].read())['content'][0]['text'].strip()
    except Exception:
        brief = (
            f"[Bedrock unavailable] High return risk ({risk_score:.0%}). "
            "Add size chart. Improve photography."
        )

    table.update_item(
        Key={'tenant_id': tenant_id, 'order_id': order_id},
        UpdateExpression=(
            "SET causal_attributions=:a, intervention_brief=:b, analysis_status=:s"
        ),
        ExpressionAttributeValues={
            ':a': attributions,
            ':b': brief,
            ':s': 'complete'
        },
    )

    try:
        eventbridge.put_events(Entries=[{
            'Source': 'rooscloset.mirror',
            'DetailType': 'CausalAttributionComplete',
            'Detail': json.dumps({
                'tenant_id': tenant_id,
                'order_id': order_id,
                'confidence': 0.78
            }),
            'EventBusName': EVENT_BUS_NAME,
        }])
    except Exception:
        pass

    return {'tenant_id': tenant_id, 'order_id': order_id, 'status': 'explained'}
EOF

cat > mirror/handlers/prescribe.py << 'EOF'
"""MIRROR: Intervention prescription generator"""
import json
import os
import boto3
from datetime import datetime, timezone

bedrock = boto3.client('bedrock-runtime')
dynamodb = boto3.resource('dynamodb')

RETURN_TABLE = os.environ['RETURN_TABLE']
BEDROCK_MODEL_ID = os.environ['BEDROCK_MODEL_ID']
table = dynamodb.Table(RETURN_TABLE)


def handler(event, context):
    if 'httpMethod' in event:
        sku_id = event.get('pathParameters', {}).get('sku_id', '')
        return {
            'statusCode': 200,
            'headers': {'Content-Type': 'application/json'},
            'body': json.dumps({
                'sku_id': sku_id,
                'interventions': [
                    {
                        'rank': 1,
                        'action': 'Add size chart',
                        'estimated_impact': '-12% returns',
                        'effort': 'low'
                    },
                    {
                        'rank': 2,
                        'action': 'Retake product photography (color accuracy)',
                        'estimated_impact': '-8% returns',
                        'effort': 'medium'
                    },
                ],
                'generated_at': datetime.now(timezone.utc).isoformat(),
            }),
        }

    detail = event.get('detail', event)
    tenant_id = detail.get('tenant_id', 'unknown')
    order_id = detail.get('order_id', 'unknown')

    try:
        prompt = (
            "Generate a ranked list of 3 interventions for a fashion product "
            "with high return risk due to sizing uncertainty and photography issues. "
            "For each: action, estimated return rate reduction, implementation effort, "
            "and ROI estimate assuming $50 avg order value and 30% return rate. "
            "Format as JSON array."
        )
        response = bedrock.invoke_model(
            modelId=BEDROCK_MODEL_ID,
            body=json.dumps({
                'anthropic_version': 'bedrock-2023-05-31',
                'max_tokens': 512,
                'temperature': 0.2,
                'messages': [{'role': 'user', 'content': prompt}],
            }),
        )
        prescription = json.loads(
            response['body'].read()
        )['content'][0]['text'].strip()
    except Exception:
        prescription = json.dumps([{
            'action': 'Add size chart',
            'impact': '-12%',
            'effort': 'low'
        }])

    table.update_item(
        Key={'tenant_id': tenant_id, 'order_id': order_id},
        UpdateExpression="SET prescription=:p, prescribed_at=:t",
        ExpressionAttributeValues={
            ':p': prescription,
            ':t': datetime.now(timezone.utc).isoformat()
        },
    )

    return {'status': 'prescribed', 'tenant_id': tenant_id, 'order_id': order_id}
EOF

echo "=== All source files written. Run rc_patch_haiku.sh next. ==="