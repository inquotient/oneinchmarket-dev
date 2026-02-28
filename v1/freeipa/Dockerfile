FROM freeipa/freeipa-server:fedora-rawhide

# systemd 컨테이너 플래그
ENV container=docker \
    SYSTEMD_IGNORE_CHROOT=1

# firstboot 스크립트 & systemd unit 배치
COPY ipa-firstboot.sh /usr/local/sbin/ipa-firstboot.sh
COPY ipa-firstboot.service /etc/systemd/system/ipa-firstboot.service

RUN chmod +x /usr/local/sbin/ipa-firstboot.sh && \
    mkdir -p /etc/systemd/system/multi-user.target.wants && \
    ln -s /etc/systemd/system/ipa-firstboot.service \
      /etc/systemd/system/multi-user.target.wants/ipa-firstboot.service

# 데이터 볼륨 디렉터리 (설치 플래그 등)
RUN mkdir -p /data && chown root:root /data

# PID1 = systemd
CMD ["/usr/local/sbin/init"]