#!/bin/sh

# configure.sh pkill matches this script path. Ignore that signal until Java is up.
STOP=0
trap 'if [ -n "$PID" ]; then STOP=1; kill -TERM $PID 2>/dev/null; fi' TERM INT
rm -f /opt/JDownloader/app/JDownloader.jar.* 2> /dev/null
rm -f /opt/JDownloader/app/JDownloader.pid 2> /dev/null

# Define PUID/GID workaround for closed systems
if [ -n "$PUID" ] && [ $(id -u) -eq 0 ]; then
    adduser jdown -D 2> /dev/null || useradd jdown 2> /dev/null
    usermod -u $PUID jdown
fi

if [ -n "$GID" ] && [ $(id -u) -eq 0 ]; then
    groupmod -g $GID jdown > /dev/null 2>&1 ||: usermod -g $GID jdown
fi

# Login user with docker secret or env credentials - Please prefer command way
if [ -n "$FILE_MYJD_USER" ] && [ -n "$FILE_MYJD_PASSWORD" ]; then
    configure $(cat "/run/secrets/$FILE_MYJD_USER") $(cat "/run/secrets/$FILE_MYJD_PASSWORD")
elif [ -n "$MYJD_USER" ] && [ -n "$MYJD_PASSWORD" ]; then
    configure "$MYJD_USER" "$MYJD_PASSWORD"
fi

# Defining device name to jdownloader interface - please prefer this method than changing on MyJDownloader to keep correct binding
if [ -n "$MYJD_DEVICE_NAME" ]; then
    sed -Ei "s/\"devicename\":\"[^\"]*\"/\"devicename\":\"$MYJD_DEVICE_NAME\"/" /opt/JDownloader/app/cfg/org.jdownloader.api.myjdownloader.MyJDownloaderSettings.json
fi

# Debugging helper - if the container crashes, create a file called "jdownloader-block.txt" in the download folder
# The container will not terminate (and you can run "docker exec -it ... bash")
if [ -f /opt/JDownloader/Downloads/jdownloader-block.txt ]; then
    sleep 1000000
fi

# app/ is often an empty volume. The image directories underneath are hidden.
mkdir -p /opt/JDownloader/app/libs /opt/JDownloader/app/tmp

prepare_jdownloader() {
    # Copy libs if not copied yet
    if [ ! -f /opt/JDownloader/app/libs/sevenzipjbinding1509.jar ]; then
        cp /opt/JDownloader/libs/*.jar /opt/JDownloader/app/libs/
    fi

    # Copy if no JDownloader exists
    if [ ! -f /opt/JDownloader/app/JDownloader.jar ]; then
        rm -f /opt/JDownloader/app/Core.jar
        cp /opt/JDownloader/JDownloader.jar /opt/JDownloader/app/
    fi

    # Check JDownloader.jar integrity and removes it in case it's not
    if ! jar tvf /opt/JDownloader/app/JDownloader.jar > /dev/null 2>&1; then
        rm -f /opt/JDownloader/app/JDownloader.jar /opt/JDownloader/app/Core.jar
    fi

    # Check if JDownloader.jar exists, or if there is an interrupted update
    if [ ! -f /opt/JDownloader/app/JDownloader.jar ] && [ -f /opt/JDownloader/app/tmp/update/self/JDU/JDownloader.jar ]; then
        rm -f /opt/JDownloader/app/Core.jar
        cp /opt/JDownloader/app/tmp/update/self/JDU/JDownloader.jar /opt/JDownloader/app/
    fi

    if [ ! -f /opt/JDownloader/app/JDownloader.jar ]; then
        cp /opt/JDownloader/JDownloader.jar /opt/JDownloader/app/
    fi
}

# Defines umask - should respect octal format
if echo "$UMASK" | grep -Eq '0[0-7]{3}' ; then
    echo "Defining umask to $UMASK"
    umask "$UMASK"
fi

if [ -n "$PUID" ] && [ $(id -u) -eq 0 ]; then
    chown -R ${PUID}:${GID} /opt/JDownloader/Downloads
fi

# -norestart tells JDownloader to exit after a self-update instead of spawning
# a new JVM. Relaunch in this same container so the updated files survive.
# Kubernetes drops the container writable layer when the process exits; exiting
# here makes every start repeat the update.
while true; do
    prepare_jdownloader

    if [ -n "$PUID" ] && [ $(id -u) -eq 0 ]; then
        chown -R ${PUID}:${GID} /opt/JDownloader/app
        su jdown -c '${JAVA_HOME}/bin/java -Dsun.jnu.encoding=UTF-8 -Dfile.encoding=UTF-8 -Djava.awt.headless=true ${VMARGS} -jar /opt/JDownloader/app/JDownloader.jar -norestart' &
    else
        java -Dsun.jnu.encoding=UTF-8 -Dfile.encoding=UTF-8 -Djava.awt.headless=true $VMARGS -jar /opt/JDownloader/app/JDownloader.jar -norestart &
    fi
    PID=$!
    wait $PID || true

    if [ "$STOP" -eq 1 ]; then
        exit 0
    fi

    # A helper JVM may still be applying the update. Do not start a second copy.
    while pgrep java >/dev/null 2>&1; do
        if [ "$STOP" -eq 1 ]; then
            pkill -TERM java 2>/dev/null || true
            exit 0
        fi
        sleep 1
    done

    echo "JDownloader exited after update; starting again"
    sleep 2
done
