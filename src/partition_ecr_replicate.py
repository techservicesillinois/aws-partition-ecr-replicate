"""
Replicate an ECR Image between AWS partitions, using IAM credentials. If the
source and destination repositories are in the same AWS partition then you
should use ECR Replication instead.

Features:

- Uses IAM User credentials to perform the replication.
- Uses an SQS FIFO Queue to serialize events for the image tag. This
  processes events in the order they arrive to EventBridge, which may not be
  the same as the order they occurred.
"""
from argparse import ArgumentParser
from base64 import b64decode
from collections import namedtuple
import json
import logging
import math
import os
import sys
from time import time
from uuid import uuid4

import boto3
from boto3.dynamodb import conditions
import docker

DST_REPO_REGION = os.environ.get('DEST_REPO_REGION')
DST_REGISTRY_ID = os.environ.get('DEST_REGISTRY_ID')
DST_SECRET      = os.environ.get('DEST_SECRET')

SRC_REPO_REGION = os.environ.get('SRC_REPO_REGION')
SRC_REGISTRY_ID = os.environ.get('SRC_REGISTRY_ID')

IMAGES_QUEUE        = os.environ.get('IMAGES_QUEUE')
IMAGES_TASKDEF      = os.environ.get('IMAGES_TASKDEF')
IMAGES_TASK_CLUSTER = os.environ.get('IMAGES_TASK_CLUSTER', 'default')
IMAGES_TASK_SUBNETS = list(filter(
    bool,
    os.environ.get('IMAGES_TASK_SUBNETS', '').split(',')
))
IMAGES_TASK_SECURITY_GROUPS = list(filter(
    bool,
    os.environ.get('IMAGES_TASK_SECURITY_GROUPS', '').split(',')
))

RECORDS_TABLE   = os.environ.get('RECORDS_TABLE')
RECORDS_EXPIRES = int(os.environ.get('RECORDS_TTL', '3600'))
RESULTS_EXPIRES = int(os.environ.get('RESULTS_TTL', '60'))

LOGGING_LEVEL = getattr(
    logging,
    os.environ.get('LOGGING_LEVEL', 'INFO'),
    logging.INFO
)

ECRRegistry = namedtuple('ECRRegistry', ['url', 'clnt'])

logger = logging.getLogger(__name__)
logger.setLevel(LOGGING_LEVEL)

docker_clnt = docker.from_env()

ddb_rsrc = boto3.resource('dynamodb')
ecs_clnt = boto3.client('ecs')
sm_clnt = boto3.client('secretsmanager')
sqs_rsrc = boto3.resource('sqs')

def get_dst_creds(secret_id=DST_SECRET):
    """
    Get the destination credentials from Secrets Manager. It expects the secret
    to have these fields: accesskey, secretaccesskey, region.

    Args:
        secret_id (str): the name or ARN of the secret.
    """
    res = sm_clnt.get_secret_value(SecretId=secret_id)
    data = json.loads(res['SecretString'])

    if not DST_REPO_REGION:
        raise ValueError('DEST_REPO_REGION is required')
    creds = {
        'aws_access_key_id': data['accesskey'],
        'aws_secret_access_key': data['secretaccesskey'],
        'region_name': DST_REPO_REGION,
    }

    return creds

def login():
    """
    Log in to the source and destination ECR registries.

    Returns:
        str, str: URL of the source and destination registries.
    """
    kwargs = {}
    if SRC_REPO_REGION:
        kwargs['region_name'] = SRC_REPO_REGION
    src_registry_url = login_registry(
        registry_id=SRC_REGISTRY_ID,
        session_kwargs=kwargs
    )

    creds = get_dst_creds()
    dst_registry_url = login_registry(
        registry_id=DST_REGISTRY_ID,
        session_kwargs=creds
    )

    return src_registry_url, dst_registry_url

def login_registry(registry_id=None, session_kwargs=None):
    """
    Login to an ECR registry. If the registry_id is not provided then it will
    use the registry in the current AWS account. If the session_kwargs is not
    provided then it will use the default boto3 session.

    Args:
        registry_id (str): the registry ID to login to.
        session_kwargs (dict): the session kwargs to use for the boto3 client.

    Returns:
        str: the registry URL after authentication.
    """
    if session_kwargs is None:
        session_kwargs = {}

    ecr_clnt = boto3.client('ecr', **session_kwargs)

    region_name = ecr_clnt.meta.region_name
    if not registry_id:
        sts_clnt = boto3.client('sts', **session_kwargs)
        res = sts_clnt.get_caller_identity()
        registry_id = res['Account']

    logger.info(
        'Getting authorization token to registry %(registry_id)s in region %(region)s',
        {'registry_id': registry_id, 'region': region_name}
    )
    res = ecr_clnt.get_authorization_token(registryIds=[registry_id])
    if not res['authorizationData']:
        raise ValueError('No authorization data returned')

    token = b64decode(res['authorizationData'][0]['authorizationToken']).decode('ascii')
    username, password = token.split(':', 1)
    if not username:
        raise ValueError('No username in authorization token')
    if not password:
        raise ValueError('No password in authorization token')

    registry_url = f"{registry_id}.dkr.ecr.{region_name}.amazonaws.com"
    logger.info(
        'Logging in to registry %(registry_url)s',
        {'registry_url': registry_url}
    )
    res = docker_clnt.login(
        username=username,
        password=password,
        registry=registry_url,
    )
    logger.debug('Login response: %(res)r', {'res': res})

    return ECRRegistry(registry_url, ecr_clnt)

def store_records(records):
    """
    Stores records from SQS into DynamoDB. This will deserialize the body
    ahead of time, and store the record with a TTL (that should match the
    SQS visibility setting).

    Args:
        records (list): the records to store.

    Returns:
        str: the stored records ID.
    """
    item_id = str(uuid4())
    item_records = []
    for record in records:
        try:
            record_body = json.loads(record['body'])
        except json.JSONDecodeError:
            logger.exception(
                '[%(id)s] Unable to decode record body: %(body)s',
                {'id': item_id, 'body': record['body']}
            )
            record_body = record['body']

        item_records.append({
            'MessageId': record['messageId'],
            'ReceiptHandle': record['receiptHandle'],
            'Body': record_body,
        })


    table = ddb_rsrc.Table(RECORDS_TABLE)
    logger.debug(
        '[%(id)s] Storing %(count)d records',
        {'id': item_id, 'count': len(item_records)}
    )
    table.put_item(
        Item={
            'ID': item_id,
            'Type': 'records',
            'Records': item_records,
            'Expires': int(time()) + RECORDS_EXPIRES,
        },
    )

    return item_id

def store_results(item_id, failure_message_ids):
    """
    Stores results from records into DynamoDB. This will build a Results
    attribute that is suitable for returning from Lambda and update the
    TTL.

    Args:
        failure_message_ids (list): the messages that failed to process.
    """
    results = {
        'batchItemFailures': [ {'itemIdentifier': msg_id} for msg_id in failure_message_ids ],
    }

    table = ddb_rsrc.Table(RECORDS_TABLE)
    logger.debug(
        '[%(id)s] Storing %(count)d failure results',
        {'id': item_id, 'count': len(failure_message_ids)}
    )
    table.put_item(
        Item={
            'ID': item_id,
            'Type': 'results',
            'Results': results,
            'Expires': int(time()) + RESULTS_EXPIRES,
        },
        ConditionExpression=conditions.Attr('ID').not_exists(),
    )

def retrieve_records(item_id):
    """
    Retrieve records from DynamoDB.

    Args:
        item_id (str): the records ID to retrieve.

    Returns:
        list: the records stored.
    """
    table = ddb_rsrc.Table(RECORDS_TABLE)
    try:
        res = table.get_item(Key={'ID': item_id, 'Type': 'records'})
        if 'Item' not in res:
            logger.warning(
                '[%(id)s] No records found',
                {'id': item_id}
            )
            return []

        return res['Item']['Records']
    finally:
        logger.debug(
            '[%(id)s] Deleting records item',
            {'id': item_id}
        )
        try:
            table.delete_item(Key={'Id': item_id, 'Type': 'records'})
        except Exception: # pylint: disable=broad-except
            logger.exception(
                '[%(id)s] Unable to delete records',
                {'id': item_id}
            )

def retrieve_results(item_id):
    """
    Retrieve results from DynamoDB. This will delete the results after they
    have been retrieved.

    Args:
        item_id (str): the records ID to retrieve.

    Returns:
        list: the results stored.
    """
    table = ddb_rsrc.Table(RECORDS_TABLE)
    try:
        res = table.get_item(Key={'ID': item_id, 'Type': 'results'})
        if 'Item' not in res:
            logger.warning(
                '[%(id)s] No results found',
                {'id': item_id}
            )
            return {'batchItemFailures': []}

        return res['Item']['Results']
    finally:
        logger.debug(
            '[%(id)s] Deleting results item',
            {'id': item_id}
        )
        try:
            table.delete_item(Key={'Id': item_id, 'Type': 'results'})
        except Exception: # pylint: disable=broad-except
            logger.exception(
                '[%(id)s] Unable to delete results',
                {'id': item_id}
            )

def task_start(records_id, context, _logger):
    """
    Start the ECS Task to replicate the images. Does not return until the task
    has reached the running state.

    Args:
        records_id (str): the records ID to process.
        context (obj): the Lambda context object.
        _logger (obj): the logger to use.

    Returns:
        str: the task ARN that was started.
    """
    _logger.debug(
        'Running task %(taskdef)s',
        {'taskdef': IMAGES_TASKDEF}
    )
    res = ecs_clnt.run_task(
        cluster=IMAGES_TASK_CLUSTER,
        task_definition=IMAGES_TASKDEF,
        count=1,
        launchType='FARGATE',
        networkConfiguration={
            'awsvpcConfiguration': {
                'subnets': IMAGES_TASK_SUBNETS,
                'securityGroups': IMAGES_TASK_SECURITY_GROUPS,
                'assignPublicIp': 'DISABLED',
            }
        },
        overrides={
            'containerOverrides': [
                {
                    'name': 'replicate',
                    'command': [ records_id ],
                },
            ],
        },
        startedBy=f"lambda:{context.function_name}",
    )

    if not res['tasks']:
        raise RuntimeError('No tasks started')
    task_arn = res['tasks'][0]['taskArn']
    _logger.info(
        'Started task %(task_arn)s',
        {'task_arn': task_arn}
    )

    wait_for_task(task_arn, 'running', context, _logger)
    return task_arn

def task_join(task_arn, context, _logger):
    """
    Wait for a task to reach a state, and check that the first container exited
    successfully. If the task did not exit cleanly then raise an exception.

    Args:
        task_arn (str): the task ARN to wait for.
        context (obj): the Lambda context object.
        _logger (obj): the logger to use.
    """
    task = wait_for_task(task_arn, 'stopped', context, _logger)
    if not task['containers']:
        raise RuntimeError('No containers found')
    container = task['containers'][0]

    if task['stopCode'] != 'EssentialContainerExited' or container['exitCode'] != 0:
        _logger.error(
            'Task failed (%(task_arn)s): %(stop_code)s - exit code %(exit_code)d',
            {
                'task_arn': task_arn,
                'stop_code': task['stopCode'],
                'exit_code': container['exitCode'],
            }
        )
        raise RuntimeError(
            f"Task did not exit cleanly: {task['stopCode']} (exit code: {container['exitCode']})"
        )

def wait_for_task(task_arn, state, context, _logger):
    """
    Wait for a task to reach a state, and check that the first container exited
    successfully. If the task did not exit cleanly then raise an exception.

    Args:
        task_arn (str): the task ARN to wait for.
        context (obj): the Lambda context object.
        _logger (obj): the logger to use.

    Returns:
        dict: the task object from DescribeTasks.
    """
    # Wait the remaining time for the task to complete, minus 5 seconds for
    # us to successfully shutdown.
    max_attempts = math.floor(
        (context.get_remaining_time_in_millis() - 5000) / 1000 / 10
    )
    if max_attempts < 1:
        raise ValueError('Not enough time to wait for task')

    _logger.debug(
        'Waiting for task %(task_arn)s to %(state)s (max_attempts=%(max_attempts)d)',
        {'task_arn': task_arn, 'state': state, 'max_attempts': max_attempts}
    )
    waiter = ecs_clnt.get_waiter(f"tasks_{state}")
    waiter.wait(
        cluster=IMAGES_TASK_CLUSTER,
        tasks=[task_arn],
        WaiterConfig={
            'Delay': 10,
            'MaxAttempts': max_attempts,
        }
    )

    res = ecs_clnt.describe_tasks(
        cluster=IMAGES_TASK_CLUSTER,
        tasks=[task_arn],
    )
    if not res['tasks']:
        raise RuntimeError('No tasks found')
    return res['tasks'][0]


class ECRImage:
    """
    An ECR Image object that can be replicated to another repository.
    """
    # pylint: disable=too-many-instance-attributes

    def __init__(self, src_registry, dst_registry, repo_name, image_digest):
        self._logger = logger.getChild(f"ECRImage({repo_name}@{image_digest})")

        self._image_digest = image_digest
        self._repo_name = repo_name
        self._src_registry = src_registry
        self._src_repo = f"{src_registry.url}/{repo_name}"
        self._dst_registry = dst_registry
        self._dst_repo = f"{dst_registry.url}/{repo_name}"

        self._logger.debug(
            'Pulling image from %(registry_url)s',
            {'registry_url': self._src_registry.url}
        )
        self._image = docker_clnt.images.pull(self._src_repo, image_digest)

    @property
    def image(self):
        """ Docker API image. """
        return self._image

    @property
    def image_digest(self):
        """ Image digest. """
        return self._image_digest

    @property
    def src_registry(self):
        """ Source registry tuple. """
        return self._src_registry

    @property
    def src_repo(self):
        """ Source repository URL. """
        return self._src_repo

    @property
    def dst_registry(self):
        """ Destination registry tuple. """
        return self._dst_registry

    @property
    def dst_repo(self):
        """ Destination repository URL. """
        return self._dst_repo

    def replicate_delete(self, image_tag=None):
        """
        Replicate the image deletion to the destination repository.

        Args:
            image_tag (str): the tag of the image to delete.
        """
        if image_tag:
            self._logger.info(
                'Deleting image %(dst_repo)s:%(tag)s',
                {'dst_repo': self._dst_repo, 'tag': image_tag}
            )
            image_id = {'imageTag': image_tag}
        else:
            self._logger.info(
                'Deleting image %(dst_repo)s',
                {'dst_repo': self._dst_repo}
            )
            image_id = {'imageDigest': self._image_digest}

        self._dst_registry.clnt.batch_delete_image(
            repositoryName=self._repo_name,
            imageIds=[image_id],
        )

    def replicate_push(self, image_tag):
        """
        Replicate the image to the destination repository.

        Args:
            image_tag (str): the tag of the image to push.
        """
        if not image_tag:
            raise ValueError('image_tag is required')

        self._logger.info(
            'Tagging image with %(dst_repo)s:%(tag)s',
            {'dst_repo': self._dst_repo, 'tag': image_tag}
        )
        self._image.tag(self._dst_repo, tag=image_tag)

        self._logger.info(
            'Pushing image to %(registry_url)s',
            {'registry_url': self._dst_registry.url}
        )
        progress = docker_clnt.images.push(
            self._dst_repo,
            tag=image_tag,
            stream=True,
            decode=True,
        )
        for update in progress:
            update_status = update.get('status')
            update_id = update.get('id')

            if update_id and update_status:
                self._logger.debug(
                    'Push %(id)s: %(status)s',
                    {'id': update_id, 'status': update_status}
                )
            elif update_status:
                self._logger.debug('Push: %(status)s', {'status': update_status})
            else:
                self._logger.debug('Push: %(update)r', {'update': update})

def event_handler(event, context):
    """
    Take an ECR object event, determine if we should process it, and if so put
    it in the SQS FIFO Queue. This will only process PUSH and DELETE events.

    Args:
        event (dict): ECR image event.
        context (obj): Lambda context.
    """
    # pylint: disable=unused-argument
    if not IMAGES_QUEUE:
        raise ValueError('IMAGES_QUEUE is required')

    detail      = event['detail']

    repo_name    = detail['repository-name']
    image_digest = detail['image-digest']
    image_tag    = detail.get('image-tag')
    action_type  = detail['action-type']

    img_logger = logger.getChild(f"Image({repo_name}@{image_digest})")
    img_logger.debug(
        'Handling event: %(event)r',
        {'event': event}
    )

    if action_type not in {'PUSH', 'DELETE'}:
        img_logger.debug('Skipping: %(type)s', {'type': action_type})
        return

    queue = sqs_rsrc.Queue(IMAGES_QUEUE)
    res = queue.send_message(
        MessageBody=json.dumps(detail),
        MessageGroupId=image_tag if image_tag else image_digest,
    )

    img_logger.info(
        'Queued event %(type)s: %(msg_id)s',
        {
            'type': action_type,
            'msg_id': res['MessageId'],
        }
    )

def queue_handler(event, context):
    """
    Take records from the SQS FIFO Queue for objects, place them in a temporary
    file, and start the ECS Task.

    Args:
        event (dict): SQS records of events.
        context (obj): Lambda context.
    """
    # pylint: disable=unused-argument
    if not IMAGES_QUEUE:
        raise ValueError('IMAGES_QUEUE is required')
    if not IMAGES_TASKDEF:
        raise ValueError('IMAGES_TASKDEF is required')
    if not IMAGES_TASK_CLUSTER:
        raise ValueError('IMAGES_TASK_CLUSTER is required')
    if not IMAGES_TASK_SECURITY_GROUPS:
        raise ValueError('IMAGES_TASK_SECURITY_GROUPS is required')
    if not IMAGES_TASK_SUBNETS:
        raise ValueError('IMAGES_TASK_SUBNETS is required')
    if not RECORDS_TABLE:
        raise ValueError('RECORDS_TABLE is required')

    records_id = store_records(event['Records'])
    rec_logger = logger.getChild(f"Records({records_id})")

    task_arn = task_start(records_id, context, rec_logger)
    task_join(task_arn, context, rec_logger)

    return retrieve_results(records_id)

def main(records_id):
    """
    Process the records in dynamodb, replicating the image PUSH and DELETE
    actions. This will delete the DynamoDB item after it has been read, but
    before we know if processing was successful. If there was an error in
    processing then the SQS Queue will handle the retry. Successfully processed
    records will be deleted from the queue.

    Args:
        records_id (str): records item to process.
    """
    if not DST_REPO_REGION:
        raise ValueError('DEST_REPO_REGION is required')
    if not DST_SECRET:
        raise ValueError('DEST_SECRET is required')
    if not RECORDS_TABLE:
        raise ValueError('RECORDS_TABLE is required')

    if not records_id:
        raise ValueError('records_id is required')

    failure_message_ids = []
    def _failure(_record):
        failure_message_ids.append(_record['MessageId'])

    src_registry, dst_registry = login()

    images = {}
    for record in retrieve_records(records_id):
        # There errors are not ones we can retry, so we log and continue.
        try:
            detail = record['Body']

            repo_name    = detail['repository-name']
            image_digest = detail['image-digest']
            image_tag    = detail.get('image-tag')
            action_type  = detail['action-type']
        except KeyError:
            logger.exception(
                'Missing field in record: %(record)r',
                {'record': record}
            )
            continue

        try:
            if image_digest in images:
                image = images[image_digest]
            else:
                image = ECRImage(
                    src_registry=src_registry,
                    dst_registry=dst_registry,
                    repo_name=repo_name,
                    image_digest=image_digest
                )
                images[image_digest] = image

            if action_type == 'PUSH':
                image.replicate_push(image_tag)
            elif action_type == 'DELETE':
                image.replicate_delete(image_tag)
        except Exception: # pylint: disable=broad-except
            logger.exception(
                'Error processing record: %(record)r',
                {'record': record}
            )
            _failure(record)

    store_results(records_id, failure_message_ids)

def parse_args():
    """
    Parse the command line arguments.
    """

    parser = ArgumentParser(description='Partition ECR Replication')
    parser.add_argument(
        '--debug', '-d',
        action='store_true',
        default=(LOGGING_LEVEL == logging.DEBUG),
        help='Enable debug logging',
    )
    parser.add_argument(
        'records_id',
        help='DynamoDB records item to process',
    )

    return parser.parse_args()

if __name__ == '__main__':
    logging.basicConfig(
        level=logging.INFO,
        stream=sys.stderr,
    )
    args = parse_args()
    if args.debug:
        logger.setLevel(logging.DEBUG)

    main(args.records_id)