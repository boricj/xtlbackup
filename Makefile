
DESTDIR?=/usr

VERSION=0.0

all:

install:
	mkdir -p ${DESTDIR}/sbin
	install xtlbackup.pl ${DESTDIR}/sbin/xtlbackup

uninstall:
	rm -f ${DESTDIR}/sbin/xtlbackup

build-deb:
	mkdir -p ./xtlbackup-${VERSION}
	fakeroot make DESTDIR=./xtlbackup-${VERSION}/usr install
	mkdir -p ./xtlbackup-${VERSION}/DEBIAN
	sh -c "VERSION=${VERSION}; echo \"$$(cat DEBIAN/control)\"" > ./xtlbackup-${VERSION}/DEBIAN/control
	fakeroot dpkg-deb --build xtlbackup-${VERSION}

clean:
	rm -rf ./xtlbackup-${VERSION}
	rm -rf ./xtlbackup-${VERSION}.deb
