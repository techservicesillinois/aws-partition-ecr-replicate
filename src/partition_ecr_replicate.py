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
from base64 import b64decode
from collections import namedtuple
import json
import logging
import os
from os import path
from uuid import uuid4

import boto3
import docker

RECORDS_BASE = os.environ.get('RECORDS_BASE', '/records')

DST_REPO_REGION = os.environ.get('DEST_REPO_REGION')
DST_SECRET      = os.environ.get('DEST_SECRET')

IMAGES_QUEUE        = os.environ['IMAGES_QUEUE']
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

LOGGING_LEVEL = getattr(
    logging,
    os.environ.get('LOGGING_LEVEL', 'INFO'),
    logging.INFO
)

ECRRegistry = namedtuple('ECRRegistry', ['url', 'clnt'])

logger = logging.getLogger(__name__)
logger.setLevel(LOGGING_LEVEL)

docker_clnt = docker.from_env()

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
    src_registry_url = login_registry()

    creds = get_dst_creds()
    dst_registry_url = login_registry(session_kwargs=creds)

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
    if registry_id is None:
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

def read_records(filename):
    """
    Read the records to process from the filename (relative to RECORDS_BASE).
    After the file is read, successfully or not, it will be deleted.

    Args:
        filename (str): the records file to read.

    Returns:
        list: the records to process
    """
    records_path = path.join(RECORDS_BASE, filename)
    try:
        with open(records_path, 'r', encoding='utf-8') as fp_records:
            return json.load(fp_records)
    finally:
        try:
            os.remove(records_path)
        except Exception: # pylint: disable=broad-except
            logger.exception(
                'Unable to remove records file: %(path)s',
                {'path': records_path}
            )

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
    if not IMAGES_TASKDEF:
        raise ValueError('IMAGES_TASKDEF is required')
    if not IMAGES_TASK_CLUSTER:
        raise ValueError('IMAGES_TASK_CLUSTER is required')
    if not IMAGES_TASK_SECURITY_GROUPS:
        raise ValueError('IMAGES_TASK_SECURITY_GROUPS is required')
    if not IMAGES_TASK_SUBNETS:
        raise ValueError('IMAGES_TASK_SUBNETS is required')

    records_id = str(uuid4())
    rec_logger = logger.getChild(f"Records({records_id})")

    records_path = path.join(RECORDS_BASE, f"{records_id}.json")
    rec_logger.debug(
        'Writing record to json file: %(path)s',
        {'path': records_path}
    )
    with open(records_path, 'w', encoding='utf-8') as fp_records:
        json.dump(event['Records'], fp=fp_records)

    rec_logger.debug(
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
                    'command': [ f"{records_id}.json" ],
                },
            ],
        },
        startedBy=f"lambda:{context.function_name}",
    )

    for task in res['tasks']:
        rec_logger.info(
            'Started task %(task_arn)s',
            {'task_arn': task['taskArn']}
        )

def main(filename):
    """
    Process the records in the file, replicating the image PUSH and DELETE
    actions. This will delete the file after it has been read, but before we
    know if processing was successful. If there was an error in processing then
    the SQS Queue will handle the retry. Successfully processed records will
    be deleted from the queue.

    Args:
        filename (str): records file to process.
    """
    if not DST_REPO_REGION:
        raise ValueError('DEST_REPO_REGION is required')
    if not DST_SECRET:
        raise ValueError('DEST_SECRET is required')
    if not filename:
        raise ValueError('filename is required')

    src_registry, dst_registry = login()

    records = read_records(filename)
    message_successes = []
    def _success(_record):
        message_successes.append(
            {
                'Id': _record['MessageId'],
                'ReceiptHandle': _record['ReceiptHandle'],
            }
        )

    images = {}
    for record in records:
        # There errors are not ones we can retry, so we log and continue.
        try:
            detail = json.loads(record['body'])

            repo_name    = detail['repository-name']
            image_digest = detail['image-digest']
            image_tag    = detail.get('image-tag')
            action_type  = detail['action-type']
        except json.JSONDecodeError:
            logger.exception(
                'Unable to decode record body: %(body)s',
                {'body': record['body']}
            )
            _success(record)
            continue
        except KeyError:
            logger.exception(
                'Missing field in record: %(record)r',
                {'record': record}
            )
            _success(record)
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
        else:
            _success(record)

    if message_successes:
        queue = sqs_rsrc.Queue(IMAGES_QUEUE)
        queue.delete_messages(Entries=message_successes)
