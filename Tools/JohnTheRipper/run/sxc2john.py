#!/usr/bin/env python

"""sxc2john.py processes SXC files into a format suitable
for use with JtR."""

from xml.etree.ElementTree import ElementTree
import zipfile
import sys
import base64
import binascii


def process_file(filename):
    try:
        zf = zipfile.ZipFile(filename)
    except zipfile.BadZipfile:
        sys.stderr.write("%s is not an StarOffice file!\n" % filename)
        return 2
    try:
        mf = zf.open("META-INF/manifest.xml")
    except KeyError:
        sys.stderr.write("%s is not an StarOffice file!\n" % filename)
        return 3
    #print mf.read()
    tree = ElementTree()
    tree.parse(mf)
    r = tree.getroot()

    # getiterator() is deprecated but 2.6 does not have iter()
    try :
        elements = list(r.iter())
    except :
        elements = list(r.getiterator())

    is_encrypted = False
    key_size = 16
    for i in range(0, len(elements)):
        element = elements[i]
        if element.get("{http://openoffice.org/2001/manifest}full-path") == "content.xml":
            for j in range(i + 1, i + 1 + 3):
                element = elements[j]
                data = element.get("{http://openoffice.org/2001/manifest}checksum")
                if data:
                    is_encrypted = True
                    checksum = data
                data = element.get("{http://openoffice.org/2001/manifest}initialisation-vector")
                if data:
                    iv = data
                data = element.get("{http://openoffice.org/2001/manifest}salt")
                if data:
                    salt = data
                data = element.get("{http://openoffice.org/2001/manifest}iteration-count")
                if data:
                    iteration_count = data
                data = element.get("{http://openoffice.org/2001/manifest}algorithm-name")
                if data:
                    assert(data == "Blowfish CFB")

    if not is_encrypted:
        sys.stderr.write("%s is not an encrypted StarOffice file!\n" % filename)
        return 4

    checksum = base64.decodestring(checksum.encode)
    checksum = binascii.hexlify(checksum).decode("ascii")
    iv = binascii.hexlify(base64.decodestring(iv.encode)).decode("ascii")
    salt = binascii.hexlify(base64.decodestring(salt.encode)).decode("ascii")

    try:
        content = zf.open("content.xml").read()
    except KeyError:
        sys.stderr.write("%s is not an encrypted StarOffice file, " \
                         "content.xml missing!\n" % filename)
        return 5

    algorithm_type = 0
    checksum_type = 0
    key_size = 16

    original_length = len(content)
    if original_length >= 1024:
        length = 1024
        original_length = 1024

    else:
        # pad to make length multiple of 8
        pad = "00000000"
        pad_length = original_length % 8
        if pad_length > 0:
            content = content + pad[0:pad_length]
        length = len(content)

    sys.stdout.write("%s:$sxc$*%s*%s*%s*%s*%s*%d*%s*%d*%s*%d*%d*%s\n" % \
            (filename, algorithm_type,
            checksum_type, iteration_count, key_size, checksum, len(iv) / 2,
            iv, len(salt) / 2, salt, original_length, length,
            binascii.hexlify(content[:length])))

if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.stderr.write("Usage: %s <SXC files>\n" % sys.argv[0])
        sys.exit(-1)

    for k in range(1, len(sys.argv)):
        process_file(sys.argv[k])
