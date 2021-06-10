#!/bin/bash
# File Name jenkinsFunction.sh
# ---------------------- Vars ---------------------- #
userRemote="{userRemote_name}"
commitId=$(git rev-parse --short HEAD)

if [[ "$env_name" == "feature" ]]; then
    releaseName="snapshot"
    vpcId="{vpcId}"
    branchName="$(echo $GIT_BRANCH | rev | cut -d '/' -f1 | rev)"
elif [[ "$env_name" == "alpha" ]]; then
    releaseName="rc"
    vpcId="{vpcId}"
    branchName="$(echo $env_name)"
else
    echo "build not allowed in this branch"
    exit 1
fi

packageName="${service_name}-${releaseName}.${commitId}"

function initBuildToolInfo() {
  if [[ "$build_tool" == "mvnw" ]]; then
      mvnOpts=-Dorg.slf4j.simpleLogger.log.org.apache.maven.cli.transfer.Slf4jMavenTransferListener=warn
      binBuild="mvnw"
      if [[ ${service_name} == "heimdall" ]]; then
          jarDirectory="server/target"
          buildOption="$mvnOpts -f server/pom.xml -B clean package -DskipTests"
          configDir="../server/config/*"
      else
          jarDirectory="target"
          buildOption="$mvnOpts -B clean package -DskipTests"
          configDir="../config/*"
      fi
  elif [[ "$build_tool" == "gradlew" ]]; then
      jarDirectory="build/libs"
      binBuild="gradlew"
      buildOption="clean build shadowJar -x test"
  fi
}

# ---------------------- EOV  ---------------------- #
# -------------------- Functions ------------------- #
function buildApplication() {
    [ ! -x $binBuild ] && chmod +x $binBuild
    ./$binBuild $buildOption
}

function sendNotification() {
    slackHook='{slackHook}'
    curl -X POST --data-urlencode \
        "payload={\"channel\": \"${slack_channel}\", \"username\": \"${slack_user}\", \"icon_emoji\": \":jenkins:\", \
        \"attachments\": [ { \"color\": \"${color}\", \"pretext\": \"${pretext}\", \
        \"text\": \"${text}\" } ] }" ${slackHook}
}

function packagingJavaApplication() {
    fileLatestName="latest.$env_name"

    #packaging
    [ -d ${service_name} ] && rm -rf ${service_name}
    mkdir -p ${service_name}/{conf,libs,jmx}
    (
        cd ${service_name}
        getjarFile=$(ls -1 ../$jarDirectory/*.jar)

        cp $getjarFile libs/${service_name}.jar
        cp -r $configDir conf/
        echo "{remoteAccess}" > jmx/jmxremote.access
        echo "{remotePassword}" > jmx/jmxremote.password
        chmod 600 jmx/jmxremote.access jmx/jmxremote.password
        echo $packageName > version.txt
    )
    echo $packageName > $fileLatestName
    tar zcf $packageName.tgz ${service_name}

    # check if its releaseName is snapshot
    if [[ "$releaseName" == "snapshot" ]]; then
        listPackages=$(aliyun oss ls oss://${oss_bucket}/${service_name}/ | rev | awk '{print $1}' | rev | grep "$releaseName")
        for getPackage in $listPackages
        do
            aliyun oss rm $getPackage
        done
    fi

    # Strore to bucket
    for file in $packageName.tgz $fileLatestName
    do
        aliyun oss cp $file oss://${oss_bucket}/${service_name}/ > /dev/null
    done
}

function pushToRegistry() {
    dockerRegistry="{dockerRegistry}"

    # login docker registry
    eval $(aws ecr get-login --no-include-email --region ap-southeast-1)

    # check if its releaseName is snapshot and delete
    if [[ "$releaseName" == "snapshot" ]]; then
        listImages=$(aws ecr list-images --repository-name ${service_name} | jq -r '.imageIds[] | .imageTag' | grep "$releaseName")
        for getImage in $listImages
        do
            aws ecr batch-delete-image --repository-name ${service_name} --image-ids imageTag=$getImage
        done
    fi

    # check whether Repository is Exist or not
    repositoryName=$(aws ecr describe-repositories --repository-names ${service_name} | jq -r '.repositories[] | .repositoryName')
    if [[ "${service_name}" != "${repositoryName}" ]]; then
        aws ecr create-repository --repository-name ${service_name}
    fi
    docker push ${dockerRegistry}/${service_name}:${releaseName}-${commitId}
    docker rmi $dockerRegistry/${service_name}:${releaseName}-${commitId}
}

# ------------------- Deploy ------------------- #
function deployApplication() {
    [ -f hosts ] && rm -f hosts
    [ -f deploy.sh ] && rm -f deploy.sh
    state="Running"
    hostName=$(aliyun ecs DescribeInstances --VpcId $vpcId --PageSize 100 | jq -r '.Instances.Instance[] | select((.Status == '\"$state\"') and select((.Tags.Tag[1].TagValue == '\"$env_name\"') and .Tags.Tag[3].TagValue == '\"${service_name}\"')) .HostName')
    if [[ "$env_name" == "feature" ]] || [[ "$env_name" == "alpha" ]]; then
        if echo "$hostName" | grep -q "$branchName"; then
            echo $hostName > hosts
        fi
    else
        echo $hostName >> hosts
    fi
    # ---------- Prepare Deploy ----------------- #
    cat <<EOF >>deploy.sh
#!/bin/bash
(
    cd /opt/app
    [ ! -d APP_PREV ] && mkdir APP_PREV
    sudo systemctl stop ${service_name}
    [ -d APP_PREV/${service_name} ] && rm -rf APP_PREV/${service_name}
    [ -d ${service_name} ] && mv ${service_name} APP_PREV/
    tar xf $packageName.tgz
    rm -rf $packageName.tgz

    if [[ -f ${service_name}/conf/application.properties ]]; then
        sed -i "s/PROFILE/$env_name/g" ${service_name}/conf/application.properties
    elif [[ ${service_name} == "garuda" ]]; then
        (
            cd ${service_name}/conf
            mv $env_name/* .
            find * -type d -exec rm -rf {} \;
        )
    fi

    sudo systemctl start ${service_name}
)
EOF

    for server in $(cat hosts); do
        scp deploy.sh $packageName.tgz $userRemote@${server}:/opt/app/
        ssh $userRemote@$server "bash /opt/app/deploy.sh"
        ssh $userRemote@$server "rm -f /opt/app/deploy.sh"
    done
# ---------------------- EOD --------------------- #
}

function tagVersion() {
    [ -d ${service_name} ] && rm -rf ${service_name}
    git clone git@github.com:awantunai/${service_name}.git
    (
        cd ${service_name}
        git checkout -b tagging
        git tag $tagVer
        git push origin $tagVer
    )
}

# ---------------- End of Function --------------- #
# -------------------- Action -------------------- #
action=$1

case $action in
    build)
        initBuildToolInfo
        buildApplication
        ;;
    notify)
        sendNotification
        ;;
    pack)
        initBuildToolInfo
        packagingJavaApplication
        ;;
    push)
        pushToRegistry
        ;;
    deploy)
        deployApplication
        ;;
    release)
        versionName="$2"
        tagVer="$versionName.$commitId"
        vpcId="{vpcId}"
        env_name="release"
        packageName=$(echo $packageName | sed "s/$releaseName/$versionName/g")
        initBuildToolInfo
        tagVersion
        packagingJavaApplication
        deployApplication
        ;;
    *)
        echo "No such function that refers to the parameter"
        ;;
esac
