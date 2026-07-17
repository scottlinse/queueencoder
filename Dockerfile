FROM lscr.io/linuxserver/ffmpeg:latest

# inotify-tools for the watch loop; base image already ships ffmpeg/ffprobe
# plus the Intel oneVPL/QSV + VAAPI runtime needed for Arc GPUs.
RUN apt-get update \
    && apt-get install -y --no-install-recommends inotify-tools \
    && rm -rf /var/lib/apt/lists/*

COPY encode.conf.default /defaults/encode.conf
COPY watch.sh /usr/local/bin/watch.sh
RUN chmod +x /usr/local/bin/watch.sh

ENTRYPOINT ["/usr/local/bin/watch.sh"]
