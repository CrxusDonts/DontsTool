#!/usr/bin/env python3
"""Generate and independently verify a signed Sparkle feed for a GitHub Release."""
import argparse
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
import hashlib
import html
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NS)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def metadata(dist):
    value = json.loads((dist / 'manifest.json').read_text())
    require(isinstance(value.get('version'), str) and re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', value['version']), 'A stable version is required.')
    require(isinstance(value.get('build'), str) and re.fullmatch(r'[1-9][0-9]*', value['build']), 'A positive build number is required.')
    require(value.get('name') == 'DontsTool' and value.get('platform') == 'macOS', 'Unexpected application metadata.')
    require(value.get('architectures') == ['arm64', 'x86_64'], 'A Universal archive is required.')
    require(
        value.get('signing') == 'developer-id'
        and value.get('teamId') == 'Q2K3CAKGG2'
        and value.get('notarized') is True,
        'Unexpected application signing metadata.',
    )
    require(isinstance(value.get('commit'), str) and re.fullmatch(r'[0-9a-f]{40}', value['commit']), 'A full source commit is required.')
    require(value.get('archive') == f"DontsTool-{value['version']}-macos-universal.zip", 'Unexpected archive name.')
    require(value.get('minimumSystemVersion') == '26.0', 'Unexpected minimum system version.')
    archive = dist / value['archive']
    require(not archive.is_symlink() and archive.is_file(), 'Archive must be a regular file.')
    require(hashlib.sha256(archive.read_bytes()).hexdigest() == value.get('sha256'), 'Archive SHA256 does not match manifest.')
    return value, archive


def verify_signature(public_key, signature, archive):
    try:
        require(len(base64.b64decode(public_key, validate=True)) == 32, 'Invalid public key.')
        require(len(base64.b64decode(signature, validate=True)) == 64, 'Invalid signature.')
    except (ValueError, TypeError) as error:
        raise ValueError('Invalid signing metadata.') from error
    result = subprocess.run(['swift', str(ROOT / 'scripts/verify-update-signature.swift'), public_key, signature, str(archive)], capture_output=True)
    require(result.returncode == 0, 'Archive signature does not match the embedded public key.')


def release_url(repository, version):
    require(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository), 'Invalid release repository.')
    return f'https://github.com/{repository}/releases/tag/v{version}'


def download_url(repository, value):
    release_url(repository, value['version'])
    return f"https://github.com/{repository}/releases/download/v{value['version']}/{value['archive']}"


def verify(dist, repository, public_key):
    value, archive = metadata(dist)
    tree = ET.parse(dist / 'appcast.xml')
    items = tree.findall('./channel/item')
    require(tree.getroot().tag == 'rss' and len(items) == 1, 'Exactly one stable release is required.')
    item = items[0]
    require(item.findtext(f'{{{NS}}}version') == value['build'], 'Feed build differs from archive.')
    require(item.findtext(f'{{{NS}}}shortVersionString') == value['version'], 'Feed version differs from archive.')
    require(item.findtext(f'{{{NS}}}minimumSystemVersion') == '26.0.0', 'Feed system requirements differ from archive.')
    require(item.findtext('link') == release_url(repository, value['version']), 'Unexpected release link.')
    enclosures = item.findall('enclosure')
    require(len(enclosures) == 1, 'Exactly one archive is required.')
    enclosure = enclosures[0]
    require(enclosure.get('url') == download_url(repository, value), 'Unexpected download URL.')
    require(enclosure.get('length') == str(archive.stat().st_size), 'Feed archive size differs from archive.')
    require(enclosure.get('type') == 'application/octet-stream', 'Unexpected download type.')
    verify_signature(public_key, enclosure.get(f'{{{NS}}}edSignature'), archive)


def generate(args):
    value, archive = metadata(args.dist)
    # Never fall back to a developer's unrelated Keychain identity.
    private_key = args.key_file.read_bytes().strip() if args.key_file else os.environ.get('SPARKLE_PRIVATE_KEY', '').strip().encode()
    require(bool(private_key), 'SPARKLE_PRIVATE_KEY or --key-file is required.')
    child_env = os.environ.copy()
    child_env.pop('SPARKLE_PRIVATE_KEY', None)
    result = subprocess.run([str(args.sign_tool), '--ed-key-file', '-', '-p', str(archive)], input=private_key, capture_output=True, env=child_env)
    require(result.returncode == 0, 'Sparkle archive signing failed.')
    signature = result.stdout.decode().strip()
    verify_signature(args.public_key, signature, archive)
    root = ET.Element('rss', {'version': '2.0'})
    channel = ET.SubElement(root, 'channel')
    ET.SubElement(channel, 'title').text = 'DontsTool 更新'
    ET.SubElement(channel, 'link').text = f'https://github.com/{args.repository}'
    ET.SubElement(channel, 'description').text = 'DontsTool macOS 稳定版更新'
    ET.SubElement(channel, 'language').text = 'zh-CN'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f"DontsTool {value['version']}"
    ET.SubElement(item, 'link').text = release_url(args.repository, value['version'])
    ET.SubElement(item, 'pubDate').text = format_datetime(datetime.now(timezone.utc), usegmt=True)
    ET.SubElement(item, f'{{{NS}}}version').text = value['build']
    ET.SubElement(item, f'{{{NS}}}shortVersionString').text = value['version']
    ET.SubElement(item, f'{{{NS}}}minimumSystemVersion').text = '26.0.0'
    if args.notes:
        ET.SubElement(item, 'description').text = '<pre>' + html.escape(args.notes.read_text()) + '</pre>'
    ET.SubElement(item, 'enclosure', {
        'url': download_url(args.repository, value), 'length': str(archive.stat().st_size),
        'type': 'application/octet-stream', f'{{{NS}}}edSignature': signature
    })
    temporary = args.dist / '.appcast.xml.tmp'
    try:
        ET.indent(root)
        ET.ElementTree(root).write(temporary, encoding='utf-8', xml_declaration=True)
        temporary.replace(args.dist / 'appcast.xml')
        verify(args.dist, args.repository, args.public_key)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    config = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['generate', 'verify'])
    parser.add_argument('--dist', type=Path, required=True)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--public-key', default=config['SUPublicEDKey'])
    parser.add_argument('--sign-tool', type=Path)
    parser.add_argument('--key-file', type=Path)
    parser.add_argument('--notes', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'generate':
            require(args.sign_tool is not None and args.sign_tool.is_file(), 'Resolved Sparkle sign_update tool is required.')
            generate(args)
        else:
            verify(args.dist, args.repository, args.public_key)
    except (ValueError, OSError, KeyError, TypeError, ET.ParseError) as error:
        parser.exit(1, f'Update feed rejected: {error}\n')
    print('Update feed and archive signature verified.')


if __name__ == '__main__':
    main()
