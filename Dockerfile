# Copyright (c) 2021 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#

#
# Copyright 2019-2020 JetBrains s.r.o.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# To build the cuurent Dockerfile there is the following flow:
#   $ ./projector.sh build [OPTIONS]

# Stage 1. Prepare JetBrains IDE with Projector.
#   1. Downloads JetBrains IDE packaging by given downloadUrl build argument.
#   2. If buildGradle build argument is set to false, then consumes built Projector assembly from the host.
#       2.1 Otherwise starts Gradle build of Projector Server and Projector Client.
#   3. Copies static files to the Projector assembly (entrypoint, launcher, configuration).
FROM docker.io/ubuntu:focal-20210609 as projectorAssembly
ENV PROJECTOR_DIR /projector
ENV JAVA_HOME /usr/lib/jvm/java-11-openjdk-amd64
ARG idePackagingUrl
ARG skipProjectorBuild
ARG dockerfileBaseDir
ADD projector-client $PROJECTOR_DIR/projector-client
ADD projector-server $PROJECTOR_DIR/projector-server
RUN set -ex \
    && export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get install -y --no-install-recommends curl findutils tar gzip unzip openjdk-11-jdk-headless \
    && rm -rf /var/lib/apt/lists/*
WORKDIR $PROJECTOR_DIR/projector-server
RUN if [ "$skipProjectorBuild" != "true" ]; then ./gradlew clean; else echo "Skipping Projector build"; fi \
    && if [ "$skipProjectorBuild" != "true" ]; then ./gradlew --console=plain :projector-server:distZip; else echo "Skipping Projector build"; fi \
    && cd projector-server/build/distributions \
    && find . -maxdepth 1 -type f -name projector-server-*.zip -exec mv {} projector-server.zip \;
WORKDIR /downloads
RUN curl -SL $idePackagingUrl | tar -xz \
    && find . -maxdepth 1 -type d -name * -exec mv {} $PROJECTOR_DIR/ide \;
WORKDIR $PROJECTOR_DIR
RUN set -ex \
    && cp projector-server/projector-server/build/distributions/projector-server.zip . \
    && rm -rf projector-client \
    && rm -rf projector-server \
    && unzip projector-server.zip \
    && rm projector-server.zip \
    && find . -maxdepth 1 -type d -name projector-server-* -exec mv {} projector-server \; \
    && mv projector-server ide/projector-server \
    && chmod 644 ide/projector-server/lib/*
ADD $dockerfileBaseDir/static $PROJECTOR_DIR
RUN set -ex \
    && mv ide-projector-launcher.sh ide/bin \
    && find . -exec chgrp 0 {} \; -exec chmod g+rwX {} \; \
    && find . -name "*.sh" -exec chmod +x {} \; \
    && mv projector-user/.config .default \
    && rm -rf projector-user

# Stage 2. Build the main image with necessary environment for running Projector
#   Doesn't require to be a desktop environment. Projector runs in headless mode.
FROM docker.io/ubuntu:focal-20210609
ENV PROJECTOR_USER_NAME projector-user
ENV PROJECTOR_DIR /projector
ENV HOME /home/$PROJECTOR_USER_NAME
ENV PROJECTOR_CONFIG_DIR $HOME/.config
ENV BAZELISK_VER 1.10.0
RUN set -ex \
    && export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
    curl wget git procps findutils socat \
    # Packages required by JetBrains products and AWT
    libsecret-1-0 jq libatk1.0-0 libdrm2 libfreetype6 libgbm1 libx11-xcb1 \
    libxext6 libxi6 libxrender1 libxtst6 libext2fs2 \
    # EOPP project and build dependencies
    git-lfs gnupg build-essential openjdk-11-jdk-headless python3 python3-dev \
    python3-pip python3-setuptools python3-wheel python-is-python3 sudo \
    liblzma-dev bash-completion vim \
    # Install firefox for headless testing deps, then remove it
    firefox libdbus-glib-1-2 libgtk-3.0 libxt6 \
    && apt-get -y purge firefox \
    && rm -rf /var/lib/apt/lists/* \
    && curl -sL "https://github.com/bazelbuild/bazelisk/releases/download/v${BAZELISK_VER}/bazelisk-linux-amd64" -o /usr/local/bin/bazel && chmod +x /usr/local/bin/bazel \
    && useradd -r -u 1002 -G root -d $HOME -m -s /bin/sh $PROJECTOR_USER_NAME \
    && echo "%wheel ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers \
    && mkdir /projects \
    && for f in "${HOME}" "/etc/passwd" "/etc/group /projects"; do\
            chgrp -R 0 ${f} && \
            chmod -R g+rwX ${f}; \
       done \
    && cat /etc/passwd | sed s#root:x.*#root:x:\${USER_ID}:\${GROUP_ID}::\${HOME}:/bin/bash#g > ${HOME}/passwd.template \
    && cat /etc/group | sed s#root:x:0:#root:x:0:0,\${USER_ID}:#g > ${HOME}/group.template \
    # Change permissions to allow editing of files for openshift user
    && find $HOME -exec chgrp 0 {} \; -exec chmod g+rwX {} \;

# libxshmfence1

COPY --chown=$PROJECTOR_USER_NAME:root --from=projectorAssembly $PROJECTOR_DIR $PROJECTOR_DIR

USER $PROJECTOR_USER_NAME
WORKDIR /projects
EXPOSE 8887
CMD $PROJECTOR_DIR/entrypoint.sh
