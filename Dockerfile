FROM public.ecr.aws/ubuntu/ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        gpg-agent \
        software-properties-common \
    && add-apt-repository ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
        python3.11 \
        python3-pip \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir /app
WORKDIR /app

COPY src/requirements.txt /tmp/requirements.txt
RUN python3.11 -m pip install -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt

# Copy function code
COPY src/ /app

# Set the CMD to your handler (could also be done as a parameter override outside of the Dockerfile)
ENTRYPOINT [ "python3.11", "partition_ecr_replicate.py" ]
