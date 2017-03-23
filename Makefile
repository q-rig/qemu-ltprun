JOBS=$(shell getconf _NPROCESSORS_ONLN)

KERN_API=https://api.github.com/repos/torvalds/linux
KERN_REPO=git://github.com/torvalds/linux
KERN_VER=$(shell [ -e linux-latest.json ] && jq '.name' linux-latest.json | xargs echo | sed -e 's/^v//' -e 's/-/.0-/')

QEMU_API=https://api.github.com/repos/qemu/qemu
QEMU_REPO=git://github.com/qemu/qemu
QEMU_VER=$(shell [ -e qemu-latest.json ] && jq '.tag_name' qemu-latest.json | xargs echo)

LTP_API=https://api.github.com/repos/linux-test-project/ltp
LTP_REPO=git://github.com/linux-test-project/ltp
LTP_VER=$(shell [ -e ltp-latest.json ] && jq '.tag_name' ltp-latest.json | xargs echo)

DEPLOY_REPO=https://$$GH_TOKEN@github.com/q-rig/qemu-ltprun-results.git

TODAYSTAMP=$(shell date +%Y%m%d)
DEVLOOP ?= /dev/loop7

all: all-arm64 all-armhf all-hppa
all-arm64: linux-$(KERN_VER)-arm64.tar.xz ltp-$(LTP_VER)-arm64.tar.xz
all-armhf: linux-$(KERN_VER)-armhf.tar.xz ltp-$(LTP_VER)-armhf.tar.xz
all-hppa: linux-$(KERN_VER)-parisc64.tar.xz ltp-$(LTP_VER)-hppa.tar.xz

deploy.git:
	git clone -q --depth=1 $(DEPLOY_REPO) $@
	cd $@ && git config user.name "Travis CI"
	cd $@ && git config user.email "$(USER)@$(shell hostname)"
	cd $@ && git log -1

linux-latest.json:
	curl -s $(KERN_API)/tags | jq '.[0]' >$@

qemu-latest.json:
	curl -s $(QEMU_API)/releases/latest >$@

ltp-latest.json:
	curl -s $(LTP_API)/releases/latest >$@

linux.git:
	git clone $(KERN_REPO) $@
	cd $@ && git log -1

qemu.git:
	git clone $(QEMU_REPO) $@
	cd $@ && git log -1

ltp.git:
	git clone $(LTP_REPO) $@
	cd $@ && git log -1

build-linux-arm64: linux.git
	ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- KBUILD_OUTPUT=$(PWD)/$@ $(MAKE) -C $< defconfig
	ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- KBUILD_OUTPUT=$(PWD)/$@ $(MAKE) -C $< Image.gz modules dtbs -j$(JOBS)
	qemu-system-aarch64 -M virt -m 4096 -cpu cortex-a57 -nographic -no-reboot -kernel $@/arch/arm64/boot/Image.gz -append panic=-1

build-linux-armhf: linux.git
	ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- KBUILD_OUTPUT=$(PWD)/$@ $(MAKE) -C $< multi_v7_defconfig
	ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- KBUILD_OUTPUT=$(PWD)/$@ $(MAKE) -C $< zImage modules dtbs -j$(JOBS)
	qemu-system-arm -M virt -m 4096 -nographic -no-reboot -kernel $@/arch/arm/boot/zImage -append panic=-1

build-linux-parisc64: linux.git hppa64.config
	mkdir -p $@ && cp hppa64.config $@/.config
	ARCH=parisc CROSS_COMPILE=hppa64-linux-gnu- KBUILD_OUTPUT=$(PWD)/$@ $(MAKE) -C $< olddefconfig
	ARCH=parisc CROSS_COMPILE=hppa64-linux-gnu- KBUILD_OUTPUT=$(PWD)/$@ $(MAKE) -C $< -j$(JOBS)

linux-$(KERN_VER)-arm64.tar.xz: build-linux-arm64
	mkdir -p $</staging/boot ~/bin
	cp -v bin/installkernel ~/bin
	ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_PATH=$(PWD)/$</staging/boot $(MAKE) -C $< zinstall
	ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_DTBS_PATH=$(PWD)/$</staging/boot/dtb $(MAKE) -C $< dtbs_install
	ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH=$(PWD)/$</staging $(MAKE) -C $< modules_install
	tar -C $</staging -Jcf $@ . && ls -l $@

linux-$(KERN_VER)-armhf.tar.xz: build-linux-armhf
	mkdir -p $</staging/boot ~/bin
	cp -v bin/installkernel ~/bin
	ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- INSTALL_PATH=$(PWD)/$</staging/boot $(MAKE) -C $< zinstall
	ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- INSTALL_DTBS_PATH=$(PWD)/$</staging/boot/dtb $(MAKE) -C $< dtbs_install
	ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- INSTALL_MOD_PATH=$(PWD)/$</staging $(MAKE) -C $< modules_install
	tar -C $</staging -Jcf $@ . && ls -l $@

linux-$(KERN_VER)-parisc64.tar.xz: build-linux-parisc64
	mkdir -p $</staging/boot ~/bin
	cp -v bin/installkernel ~/bin
	ARCH=parisc CROSS_COMPILE=hppa64-linux-gnu- INSTALL_PATH=$(PWD)/$</staging/boot $(MAKE) -C $< install
	ARCH=parisc CROSS_COMPILE=hppa64-linux-gnu- INSTALL_MOD_PATH=$(PWD)/$</staging $(MAKE) -C $< modules_install
	tar -C $</staging -Jcf $@ . && ls -l $@

build-ltp-arm64: HOST=aarch64-linux-gnu
build-ltp-armhf: HOST=arm-linux-gnueabihf
build-ltp-hppa:  HOST=hppa-linux-gnu
build-ltp-%: ltp-latest.json
	curl -sL $(shell jq '.assets[] | select(.content_type == "application/x-xz") | .browser_download_url' $<) | tar Jx
	mv ltp-full-$(LTP_VER) $@
	$(MAKE) -C $@ autotools
	cd $@ && CC= ./configure --with-open-posix-testsuite --with-realtime-testsuite --host=$(HOST)
	$(MAKE) -C $@ -j$(JOBS) $(SILENT)

ltp-$(LTP_VER)-%.tar.xz: build-ltp-%
	mkdir -p $</staging/etc/systemd/system/multi-user.target.wants
	$(MAKE) -C $< install DESTDIR=$(PWD)/$</staging SKIP_IDCHECK=1 $(SILENT)
	find $(PWD)/$</staging -type f -exec file \{\} \; | grep "not stripped" | cut -d: -f1 | xargs strip
	cp bin/runltp-service $</staging/opt/ltp
	cp systemd/ltp.service $</staging/etc/systemd/system
	ln -s ../ltp.service $</staging/etc/systemd/system/multi-user.target.wants/ltp.service
	tar -C $</staging -Jcf $@ . && ls -l $@

build-sid-arm64: ARCH=arm64
build-sid-arm64: QEMU_STATIC=/usr/bin/qemu-aarch64-static
#build-sid-arm64: VMDEB_OPTS=--use-uefi --grub --package efibootmgr
build-sid-arm%: ARCH=$(patsubst build-sid-%,%,$@)
build-sid-arm%: QEMU_STATIC=/usr/bin/qemu-arm-static
build-sid-arm%:
	mkdir -p $@
	[ -z "$(TRAVIS)" ] || sudo patch -f /usr/lib/python2.7/dist-packages/vmdebootstrap/constants.py patches/constants.py.patch
	sudo vmdebootstrap --verbose --owner `whoami` --size 2G --arch $(ARCH) \
	  --distribution sid --mirror http://deb.debian.org/debian --foreign $(QEMU_STATIC) \
	  --no-extlinux --no-kernel --no-update-initramfs $(VMDEB_OPTS) \
	  --customize=$(PWD)/bin/customize-vm-install.sh \
	  --image $@/sid.img

sid-latest-hppa.img.xz:
sid-latest-%.img.xz: build-sid-%
	xz -9 -c $</sid.img > $@
	ls -l $@

qemu-system-aarch64: qemu.git
	cd $< && ./configure --target-list=aarch64-softmmu
	$(MAKE) -C $< -j$(JOBS)
	ln -sf $</aarch64-softmmu/qemu-system-aarch64 .
qemu-system-arm: qemu.git
	cd $< && ./configure --target-list=arm-softmmu
	$(MAKE) -C $< -j$(JOBS)
	ln -sf $</arm-softmmu/qemu-system-arm .
qemu-system-arm64: qemu-system-aarch64
	touch $@
qemu-system-armhf: qemu-system-arm
	touch $@

prepare-run-qemu-arm64: QEMU_STATIC=/usr/bin/qemu-aarch64-static
prepare-run-qemu-armhf: QEMU_STATIC=/usr/bin/qemu-arm-static
prepare-run-qemu-%: ARCH=$(patsubst prepare-run-qemu-%,%,$@)
prepare-run-qemu-%: deploy.git sid-latest-%.img.xz qemu-system-%
	mkdir -p $@/mnt
	qemu-img create -f raw $@/ltp.img 8G
	xzcat sid-latest-$(ARCH).img.xz > $@/sid-latest-$(ARCH).img
	sudo losetup -P $(DEVLOOP) $@/sid-latest-$(ARCH).img
	sudo mount $(DEVLOOP)p1 $@/mnt
	sudo tar -C $@/mnt -Jxf $(PWD)/linux-$(KERN_VER)-$(ARCH:hppa=parisc64).tar.xz
	sudo tar -C $@/mnt -Jxf $(PWD)/ltp-$(LTP_VER)-$(ARCH).tar.xz
	sudo mkdir -p $@/mnt/opt/ltp/output
ifneq ($(LTP_CMDFILES),)
	echo "-b /dev/vdb -f $(LTP_CMDFILES) -g /opt/ltp/output/index.html -l /opt/ltp/output/tests.log -C /opt/ltp/output/tests.failed -T /opt/ltp/output/tests.todo" >ltp.args
	sudo cp --no-preserve=owner ltp.args $@/mnt/opt/ltp
endif
	sudo cp --no-preserve=owner bin/runltp-service $@/mnt/opt/ltp
	sudo cp --no-preserve=owner systemd/ltp.service $@/mnt/etc/systemd/system
	sudo cp $(QEMU_STATIC) $@/mnt/usr/bin
	sudo mv $@/mnt/etc/resolv.conf $@/mnt/etc/resolv.conf.orig
	sudo sh -c "echo nameserver 8.8.8.8 > $@/mnt/etc/resolv.conf"
	sudo chroot $@/mnt $(QEMU_STATIC) /bin/sh -c "apt-get -qq update && apt-get -qq upgrade && apt-get -qq install initramfs-tools e2fsprogs dosfstools psmisc file binutils bzip2 acl expect quota"
	sudo chroot $@/mnt $(QEMU_STATIC) /bin/sh -c "update-initramfs -c -k $(KERN_VER)"
	sudo mv $@/mnt/etc/resolv.conf.orig $@/mnt/etc/resolv.conf
	sudo mv $@/mnt/boot/* $@
	sudo umount $@/mnt
	sudo losetup -d $(DEVLOOP)

run-qemu-hppa:
run-qemu-arm64: QEMU_SYSTEM=./qemu-system-aarch64 -cpu cortex-a57
run-qemu-arm%: QEMU_SYSTEM=./qemu-system-arm
run-qemu-arm%: ARCH=$(patsubst run-qemu-%,%,$@)
run-qemu-arm%: prepare-run-qemu-arm%
	$(QEMU_SYSTEM) -M virt -m 4096 -smp 2 \
	  -kernel $</vmlinuz-$(KERN_VER) \
	  -initrd $</initrd.img-$(KERN_VER) \
	  -append "console=ttyAMA0 root=/dev/vda1 panic=-1 runltp" \
	  -drive if=none,id=hda,format=raw,file=$</sid-latest-$(ARCH).img \
	  -drive if=none,id=hdb,format=raw,file=$</ltp.img \
	  -device virtio-blk-pci,drive=hda \
	  -device virtio-blk-pci,drive=hdb \
	  -nographic -no-reboot
	@sudo losetup -P $(DEVLOOP) $</sid-latest-$(ARCH).img
	@sudo mount $(DEVLOOP)p1 $</mnt
	@sudo rm -rf $</output
	@sudo mv $</mnt/opt/ltp/output $</output
	@sudo chown -R $(USER) $</output
	@sudo umount $</mnt
	@sudo losetup -d $(DEVLOOP)
	@echo "\n##########################################################################"
	@echo "# LOG"
	@echo "##########################################################################"
	@cat $</output/tests.log
	@echo "\n##########################################################################"
	@echo "# TODO"
	@echo "##########################################################################"
	@cat $</output/tests.todo
	@echo "\n##########################################################################"
	@echo "# FAILED"
	@echo "##########################################################################"
	@if [ $$(stat -c %s $</output/tests.failed) = 0 ]; then \
		echo "# None. Congratulations!"; \
	else \
		cat $</output/tests.failed; \
	fi
	@echo "##########################################################################"

travis-skip: deploy.git linux-latest.json ltp-latest.json
	@touch travis-build-$(ARCH) travis-deploy-$(ARCH) travis-prepare-run-$(ARCH) travis-run-$(ARCH)
	@echo true > travis-skip

travis-prepare-linux: KERN_VER=$(shell [ -e linux-latest.json ] && jq '.name' linux-latest.json | xargs echo | sed -e 's/^v//' -e 's/-/.0-/')
travis-prepare-linux: travis-skip linux-latest.json
	@if [ -n "$(LTP_CMDFILES)" ]; then \
		if [ -e deploy.git/linux-$(KERN_VER)-$(ARCH:hppa=parisc64).tar.xz ]; then \
			echo "linux: tag $(KERN_VER) is already built for $(ARCH), reusing..."; \
			touch linux.git; \
			touch build-linux-$(ARCH:hppa=parisc64); \
			cp -L deploy.git/linux-$(KERN_VER)-$(ARCH:hppa=parisc64).tar.xz .; \
			echo false > travis-skip; \
		else \
			echo "missing linux $(KERN_VER), skipping run..."; \
			touch travis-prepare-ltp; \
			touch travis-prepare-sid; \
			echo true > travis-skip; \
		fi; \
	elif [ ! -e deploy.git/linux-$(KERN_VER)-$(ARCH:hppa=parisc64).tar.xz ]; then \
		if [ ! -e linux.git ]; then \
			echo 'git clone -q --depth=1 -b $(shell jq .name linux-latest.json | xargs echo) $(KERN_REPO) linux.git'; \
			git clone -q --depth=1 -b $(shell jq .name linux-latest.json | xargs echo) $(KERN_REPO) linux.git; \
			(cd linux.git && git log -1); \
		fi; \
		rm -rf travis-build-$(ARCH) travis-deploy-$(ARCH); \
		echo false > travis-skip; \
	else \
		echo "linux: tag $(KERN_VER) is already built for $(ARCH:hppa=parisc64), skipping build..."; \
		touch linux.git; \
		touch build-linux-$(ARCH:hppa=parisc64); \
		cp -L deploy.git/linux-$(KERN_VER)-$(ARCH:hppa=parisc64).tar.xz .; \
	fi

travis-prepare-ltp: LTP_VER=$(shell [ -e ltp-latest.json ] && jq '.tag_name' ltp-latest.json | xargs echo)
travis-prepare-ltp: travis-skip ltp-latest.json
	@if [ -n "$(LTP_CMDFILES)" ]; then \
		if [ -e deploy.git/ltp-$(LTP_VER)-$(ARCH).tar.xz ]; then \
			echo "ltp: release $(LTP_VER) is already built for $(ARCH), reusing..."; \
			touch build-ltp-$(ARCH); \
			cp -L deploy.git/ltp-$(LTP_VER)-$(ARCH).tar.xz .; \
			echo false > travis-skip; \
		else \
			echo "missing ltp $(LTP_VER), skipping run..."; \
			touch travis-prepare-sid; \
			echo true > travis-skip; \
		fi; \
	elif [ ! -e deploy.git/ltp-$(LTP_VER)-$(ARCH).tar.xz ]; then \
		echo 'curl -sL $(shell jq '.assets[] | select(.content_type == "application/x-xz") | .browser_download_url' ltp-latest.json) | tar Jx'; \
		curl -sL $(shell jq '.assets[] | select(.content_type == "application/x-xz") | .browser_download_url' ltp-latest.json) | tar Jx; \
		rm -rf travis-build-$(ARCH) travis-deploy-$(ARCH); \
		echo false > travis-skip; \
	else \
		echo "ltp: release $(LTP_VER) is already built for $(ARCH), skipping build..."; \
		touch build-ltp-$(ARCH); \
		cp -L deploy.git/ltp-$(LTP_VER)-$(ARCH).tar.xz .; \
	fi

travis-prepare-sid: travis-skip
	@if [ -n "$(LTP_CMDFILES)" ]; then \
		if [ -e deploy.git/sid-latest-$(ARCH).img.xz ]; then \
			echo "sid: latest is already built for $(ARCH), reusing..."; \
			touch build-sid-$(ARCH); \
			cp -L deploy.git/sid-latest-$(ARCH).img.xz .; \
			rm -rf travis-prepare-run-$(ARCH) travis-run-$(ARCH); \
			echo false > travis-skip; \
		else \
			echo "missing sid latest, skipping run..."; \
			echo true > travis-skip; \
		fi; \
	elif [ ! -e deploy.git/sid-latest-$(ARCH).img.xz ]; then \
		rm -rf travis-build-$(ARCH) travis-deploy-$(ARCH); \
		echo false > travis-skip; \
	else \
		echo "sid: latest is already built for $(ARCH), skipping build..."; \
		touch build-sid-$(ARCH); \
		ln -s deploy.git/sid-latest-$(ARCH).img.xz .; \
	fi

travis-prepare: travis-prepare-linux travis-prepare-ltp travis-prepare-sid

travis-build-%:
	$(MAKE) $(patsubst travis-build-%,all-%,$@) SILENT="-s --no-print-directory"
	$(MAKE) sid-latest-$(patsubst travis-build-%,%,$@).img.xz

travis-prepare-run-%:
	$(MAKE) $(patsubst travis-prepare-run-%,prepare-run-qemu-%,$@)

travis-run-%:
	$(MAKE) $(patsubst travis-run-%,run-qemu-%,$@)

deploy-file: deploy.git
	@any=false; \
	for each in $$(echo $(SRC)); do \
		if [ -e $$each ] && [ ! -e $</$$each ]; then \
			cp -dt $< $$each; \
			(cd $< && git add $$each); \
			any=true; \
		fi; \
	done; \
	! $$any || (cd $< && git commit -m '$(MSG)')

deploy-linux-%: ARCH=$(patsubst deploy-linux-%,%,$@)
deploy-linux-%: deploy.git
	@$(MAKE) deploy-file SRC=linux-$(KERN_VER)-$(ARCH:hppa=parisc64).tar.xz MSG='Linux $(KERN_VER) ($(ARCH:hppa=parisc64))'

deploy-ltp-%: ARCH=$(patsubst deploy-ltp-%,%,$@)
deploy-ltp-%: deploy.git
	@$(MAKE) deploy-file SRC=ltp-$(LTP_VER)-$(ARCH).tar.xz MSG='LTP $(LTP_VER) ($(ARCH))'

deploy-sid-%: ARCH=$(patsubst deploy-sid-%,%,$@)
deploy-sid-%: deploy.git
	@if [ -e sid-latest-$(ARCH).img.xz ] && [ ! -L sid-latest-$(ARCH).img.xz ]; then \
		mv sid-latest-$(ARCH).img.xz sid-$(TODAYSTAMP)-$(ARCH).img.xz; \
		ln -sf sid-$(TODAYSTAMP)-$(ARCH).img.xz sid-latest-$(ARCH).img.xz; \
		$(MAKE) deploy-file SRC="sid-*-$(ARCH).img.xz" MSG='sid ($(ARCH))'; \
	fi

deploy-ltprun-%: ARCH=$(patsubst deploy-ltprun-%,%,$@)
deploy-ltprun-%: LTPRUN_DIR=$(TODAYSTAMP)-$(TRAVIS_JOB_NUMBER)-linux-$(KERN_VER)-ltp-$(LTP_VER)-$(ARCH)
deploy-ltprun-%: deploy.git
	@if [ -e prepare-run-qemu-$(ARCH)/output ]; then \
		mkdir -p $</ltp/; \
		mv prepare-run-qemu-$(ARCH)/output $</ltp/$(LTPRUN_DIR); \
		cd $< && git add ltp/$(LTPRUN_DIR) && git commit -m 'ltprun $(KERN_VER) $(LTP_VER) ($(ARCH))'; \
	fi

deploy-arm64: deploy-linux-arm64      deploy-ltp-arm64   deploy-sid-arm64   deploy-ltprun-arm64
deploy-armhf: deploy-linux-armhf      deploy-ltp-armhf   deploy-sid-armhf   deploy-ltprun-armhf
deploy-hppa:  deploy-linux-parisc64   deploy-ltp-hppa

travis-deploy-%: deploy.git deploy-%
	@cd $< && git remote update && git rebase origin/master
	@cd $< && for i in `seq 3`; do \
		git push -q && break || echo "attempt #$$i failed, trying again in 3 seconds..." && sleep 3; \
		git remote update && git rebase origin/master || exit $$?; \
	done

clean:
	rm -rf prepare-* build-* travis-* *-latest.json
