# syntax=docker/dockerfile:1
# SPDX-License-Identifier: Apache-2.0
# Build with the repository root as the context:
#   docker build -f glazed-aws/lambda/Dockerfile .

FROM public.ecr.aws/lambda/ruby:4.0 AS builder
# git, which the gemspecs run to list their files.
RUN --mount=type=cache,target=/var/cache/dnf dnf install -y gcc gcc-c++ make git

COPY ./glazed/glazed.gemspec ${LAMBDA_TASK_ROOT}/app/glazed/glazed.gemspec
COPY ./glazed/lib/glazed/version.rb ${LAMBDA_TASK_ROOT}/app/glazed/lib/glazed/version.rb
COPY ./glazed-aws/glazed-aws.gemspec ${LAMBDA_TASK_ROOT}/app/glazed-aws/glazed-aws.gemspec
COPY ./glazed-aws/lib/glazed/aws/version.rb ${LAMBDA_TASK_ROOT}/app/glazed-aws/lib/glazed/aws/version.rb
COPY ./glazed-oxidized/glazed-oxidized.gemspec ${LAMBDA_TASK_ROOT}/app/glazed-oxidized/glazed-oxidized.gemspec
COPY ./glazed-oxidized/lib/glazed/oxidized/version.rb ${LAMBDA_TASK_ROOT}/app/glazed-oxidized/lib/glazed/oxidized/version.rb
COPY ./glazed-aws/lambda/Gemfile* ${LAMBDA_TASK_ROOT}/app/glazed-aws/lambda/
WORKDIR ${LAMBDA_TASK_ROOT}/app

ENV LANG=C.UTF-8
ENV BUNDLE_GEMFILE=${LAMBDA_TASK_ROOT}/app/glazed-aws/lambda/Gemfile
ENV BUNDLE_PATH=${LAMBDA_TASK_ROOT}/vendor/bundle
ENV BUNDLE_DEPLOYMENT=1
ENV BUNDLE_JOBS=16
RUN bundle install

FROM public.ecr.aws/lambda/ruby:4.0
# git, for git storages with a remote and the gemspecs bundler loads.
RUN --mount=type=cache,target=/var/cache/dnf dnf install -y git

COPY --from=builder ${LAMBDA_TASK_ROOT}/vendor ${LAMBDA_TASK_ROOT}/vendor
COPY . ${LAMBDA_TASK_ROOT}/app
COPY ./glazed-aws/lambda/entrypoint.rb ${LAMBDA_TASK_ROOT}/glazed_lambda_entrypoint.rb
# Oxidized's models, at the release the glazed-oxidized specs replay. Models
# added to ${OXIDIZED_HOME}/model in a derived image take their place.
ADD https://github.com/ytti/oxidized.git#f774464773d30d571e0a80e5fd704ea309449eab:lib/oxidized/model ${LAMBDA_TASK_ROOT}/oxidized/model

WORKDIR ${LAMBDA_TASK_ROOT}/app
ENV LANG=C.UTF-8
ENV BUNDLE_GEMFILE=${LAMBDA_TASK_ROOT}/app/glazed-aws/lambda/Gemfile
ENV BUNDLE_PATH=${LAMBDA_TASK_ROOT}/vendor/bundle
ENV BUNDLE_DEPLOYMENT=1
# Ruby::Box, which glazed-oxidized loads models in.
ENV RUBY_BOX=1
ENV OXIDIZED_HOME=${LAMBDA_TASK_ROOT}/oxidized
# Only /tmp is writable on Lambda, such as for ~/.ssh/known_hosts.
ENV HOME=/tmp
ENV GLAZED_CONFIG_FILE=${LAMBDA_TASK_ROOT}/glazed.json
CMD [ "glazed_lambda_entrypoint.Glazed::Aws::Lambda.handler" ]
