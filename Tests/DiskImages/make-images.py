# Writes small disk images in Parallels, QCOW2 and VMDK formats, following their specs, plus the raw
# bytes each should convert to, so the Swift converters can be checked byte for byte.
import os, random, struct, sys, zlib
out = sys.argv[1]
random.seed(7)
MB = 1 << 20

def pattern(size, density=0.4, unit=64 * 1024):
    data = bytearray(size)
    for off in range(0, size, unit):
        if random.random() < density:
            data[off:off + unit] = os.urandom(unit)
    return data

def write(name, data): open(os.path.join(out, name), 'wb').write(data)

# --- Parallels .hds ---------------------------------------------------------------------------
def hds(data, cluster_sectors=2048, ext=True, base=None, keep_zero_clusters=False):
    """An expanding image; when base is given, only clusters that differ from base are stored."""
    cluster = cluster_sectors * 512
    n = (len(data) + cluster - 1) // cluster
    header_bat = 64 + 4 * n
    data_off = ((header_bat + cluster - 1) // cluster) * cluster if ext else ((header_bat + 511) // 512) * 512
    bat = [0] * n
    body = bytearray()
    for i in range(n):
        chunk = bytes(data[i * cluster:(i + 1) * cluster]).ljust(cluster, b'\0')
        same = base is not None and chunk == bytes(base[i * cluster:(i + 1) * cluster]).ljust(cluster, b'\0')
        if same or (not keep_zero_clusters and base is None and chunk.count(0) == cluster):
            continue
        offset = data_off + len(body)
        bat[i] = offset // cluster if ext else offset // 512
        body += chunk
    header = struct.pack('<16sIIIIIQIIIQ', b'WithouFreSpacExt' if ext else b'WithoutFreeSpace', 2, 16, 32,
                         cluster_sectors, n, len(data) // 512, 0x312e3276, data_off // 512, 0, 0)
    blob = bytearray(header) + struct.pack('<%dI' % n, *bat)
    blob += b'\0' * (data_off - len(blob))
    return bytes(blob + body)

disk = pattern(24 * MB)
write('parallels-ext.raw', disk)
write('parallels-ext.hds', hds(disk))
odd = pattern(5 * MB + 512 * 7)   # a size that isn't a whole cluster
write('parallels-old.raw', odd)
write('parallels-old.hds', hds(odd, cluster_sectors=63, ext=False))

# A .pvm with a two-image snapshot chain: base, then a delta changing a few clusters.
top = bytearray(disk)
for i in random.sample(range(24), 5):
    top[i * MB:(i + 1) * MB] = os.urandom(MB) if i % 2 else bytes(MB)   # some changed to zeros too
write('parallels-chain.raw', top)
pvm = os.path.join(out, 'Debian.pvm'); hdd = os.path.join(pvm, 'harddisk.hdd')
os.makedirs(hdd, exist_ok=True)
base_guid, top_guid = '{5fbaabe3-6958-40ff-92a7-860e329aab41}', '{11111111-2222-3333-4444-555555555555}'
open(os.path.join(hdd, 'harddisk.hdd.0.%s.hds' % base_guid), 'wb').write(hds(disk))
open(os.path.join(hdd, 'harddisk.hdd.0.%s.hds' % top_guid), 'wb').write(hds(top, base=disk))
open(os.path.join(hdd, 'DiskDescriptor.xml'), 'w').write(f'''<?xml version='1.0' encoding='UTF-8'?>
<Parallels_disk_image Version="1.0">
    <Disk_Parameters>
        <Disk_size>{len(disk) // 512}</Disk_size>
        <Cylinders>48</Cylinders><PhysicalSectorSize>4096</PhysicalSectorSize><Heads>16</Heads><Sectors>32</Sectors>
        <Padding>0</Padding>
        <Encryption><Engine>{{00000000-0000-0000-0000-000000000000}}</Engine><Data></Data></Encryption>
        <UID>{{aaaaaaaa-0000-0000-0000-000000000000}}</UID><Name>harddisk</Name><Miscellaneous><CompatLevel>level2</CompatLevel><Bootable>1</Bootable></Miscellaneous>
    </Disk_Parameters>
    <StorageData>
        <Storage>
            <Start>0</Start><End>{len(disk) // 512}</End><Blocksize>2048</Blocksize>
            <Image><GUID>{base_guid}</GUID><Type>Compressed</Type><File>harddisk.hdd.0.{base_guid}.hds</File></Image>
            <Image><GUID>{top_guid}</GUID><Type>Compressed</Type><File>harddisk.hdd.0.{top_guid}.hds</File></Image>
        </Storage>
    </StorageData>
    <Snapshots>
        <TopGUID>{top_guid}</TopGUID>
        <Shot><GUID>{base_guid}</GUID><ParentGUID>{{00000000-0000-0000-0000-000000000000}}</ParentGUID></Shot>
        <Shot><GUID>{top_guid}</GUID><ParentGUID>{base_guid}</ParentGUID></Shot>
    </Snapshots>
</Parallels_disk_image>
''')
open(os.path.join(pvm, 'config.pvs'), 'w').write('''<?xml version="1.0" encoding="UTF-8"?>
<ParallelsVirtualMachine schemaVersion="1.0">
  <Identification><VmUuid>{abc}</VmUuid><VmName>Debian GNU Linux</VmName></Identification>
  <Settings><General><OsType>9</OsType><OsNumber>2309</OsNumber></General></Settings>
  <Hardware>
    <Cpu><Number>2</Number></Cpu>
    <Memory><RAM>2048</RAM></Memory>
    <Hdd id="0"><Enabled>1</Enabled><EmulatedType>1</EmulatedType><SystemName>harddisk.hdd</SystemName></Hdd>
  </Hardware>
</ParallelsVirtualMachine>
''')

# --- QCOW2 ------------------------------------------------------------------------------------
def qcow2(data, cluster_bits=16, compress=(), zero_flag=(), extended=False, backing=None, sub_zero=None):
    cs = 1 << cluster_bits
    n = (len(data) + cs - 1) // cs
    l2_entries = cs // (16 if extended else 8)
    l1_size = (n + l2_entries - 1) // l2_entries
    header_len = 112
    clusters = bytearray(cs)          # cluster 0: header
    def alloc(blob):
        nonlocal clusters
        off = len(clusters)
        clusters += blob.ljust((len(blob) + cs - 1) // cs * cs, b'\0')
        return off
    backing_name = backing.encode() if backing else b''
    l1_off = alloc(bytes(8 * l1_size))
    l2 = [[0] * (l2_entries * (2 if extended else 1)) for _ in range(l1_size)]
    compressed_area = bytearray()
    for i in range(n):
        chunk = bytes(data[i * cs:(i + 1) * cs]).ljust(cs, b'\0')
        t, j = divmod(i, l2_entries)
        if i in zero_flag and not extended:
            l2[t][j] = 1; continue
        if extended and sub_zero and i in sub_zero:
            # first half allocated, second half reads as zeros by the bitmap
            off = alloc(chunk)
            l2[t][2 * j] = off | (1 << 63); l2[t][2 * j + 1] = 0x0000FFFF | (0xFFFF0000 << 32)
            continue
        if chunk.count(0) == cs:
            continue  # unallocated: backing file or zeros
        if i in compress:
            c = zlib.compressobj(9, zlib.DEFLATED, -12); z = c.compress(chunk) + c.flush()
            off = len(clusters)
            clusters += z
            pad = (-len(clusters)) % 512; clusters += b'\0' * pad
            shift = 62 - (cluster_bits - 8)
            sectors = (off % 512 + len(z) + 511) // 512 - 1
            entry = (1 << 62) | (sectors << shift) | off
            if extended: l2[t][2 * j] = entry
            else: l2[t][j] = entry
            # realign for following allocations
            clusters += b'\0' * ((-len(clusters)) % cs)
            continue
        off = alloc(chunk)
        if extended: l2[t][2 * j] = off | (1 << 63); l2[t][2 * j + 1] = 0xFFFFFFFF
        else: l2[t][j] = off | (1 << 63)
    l1 = []
    for t in range(l1_size):
        off = alloc(struct.pack('>%dQ' % len(l2[t]), *l2[t]))
        l1.append(off | (1 << 63))
    clusters[l1_off:l1_off + 8 * l1_size] = struct.pack('>%dQ' % l1_size, *l1)
    incompat = (1 << 4) if extended else 0
    bo = header_len if backing else 0
    hdr = struct.pack('>IIQIIQIIQQIIQQQQII', 0x514649fb, 3, bo, len(backing_name), cluster_bits, len(data), 0,
                      l1_size, l1_off, 0, 0, 0, 0, incompat, 0, 0, 4, header_len)
    hdr += b'\0' * (header_len - len(hdr))
    clusters[0:len(hdr)] = hdr
    clusters[header_len:header_len + len(backing_name)] = backing_name
    return bytes(clusters)

q = pattern(6 * MB)
write('qcow2-plain.raw', q)
write('qcow2-plain.qcow2', qcow2(q, compress=set(range(0, 96, 3)), zero_flag={5, 6}))
q[5 * 65536:7 * 65536] = bytes(2 * 65536)   # zero-flag clusters read as zeros
write('qcow2-plain.raw', q)
q2 = pattern(4 * MB)
expected = bytearray(q2)
for i in (2, 3, 9):
    expected[i * 65536 + 32768:(i + 1) * 65536] = bytes(32768)
write('qcow2-ext.qcow2', qcow2(q2, extended=True, sub_zero={2, 3, 9}, compress={1, 4}))
write('qcow2-ext.raw', expected)
# backing: base raw, overlay qcow2 with only some clusters
base = pattern(3 * MB, density=0.9)
write('qcow2-base.img', base)
overlay = bytearray(3 * MB)
merged = bytearray(base)
for i in range(0, 48, 5):
    blob = os.urandom(65536); overlay[i * 65536:(i + 1) * 65536] = blob; merged[i * 65536:(i + 1) * 65536] = blob
write('qcow2-overlay.qcow2', qcow2(overlay, backing='qcow2-base.img'))
write('qcow2-overlay.raw', merged)

# --- VMDK monolithicSparse, and with deflated grains ---------------------------------------------
def vmdk(data, compressed=False, grain_sectors=128):
    grain = grain_sectors * 512
    n = (len(data) + grain - 1) // grain
    gtes = 512
    tables = (n + gtes - 1) // gtes
    gd_sector = 1 + 20          # after the header and a descriptor
    gt_sector = gd_sector + 1   # tables follow
    data_sector = gt_sector + tables * (gtes * 4 // 512)
    data_sector = (data_sector + grain_sectors - 1) // grain_sectors * grain_sectors
    gts = [0] * (tables * gtes)
    body = bytearray()
    for i in range(n):
        chunk = bytes(data[i * grain:(i + 1) * grain]).ljust(grain, b'\0')
        if chunk.count(0) == grain: continue
        sector = data_sector + len(body) // 512
        gts[i] = sector
        if compressed:
            z = zlib.compress(chunk, 9)
            blob = struct.pack('<QI', i * grain_sectors, len(z)) + z
            body += blob + b'\0' * ((-len(blob)) % 512)
        else:
            body += chunk
    flags = 3 | ((1 << 16) | (1 << 17) if compressed else 0)
    header = struct.pack('<IIIQQQQIQQQB4sH', 0x564d444b, 3 if compressed else 1, flags, len(data) // 512, grain_sectors,
                         1, 20, gtes, 0, gd_sector, data_sector, 0, b'\n \r\n', 1 if compressed else 0)
    header = header.ljust(512, b'\0')
    desc = b'# Disk DescriptorFile\nversion=1\nCID=fffffffe\nparentCID=ffffffff\ncreateType="monolithicSparse"\n'.ljust(20 * 512, b'\0')
    gd = struct.pack('<%dI' % tables, *[gt_sector + t * (gtes * 4 // 512) for t in range(tables)]).ljust(512, b'\0')
    gt = struct.pack('<%dI' % len(gts), *gts)
    blob = bytearray(header + desc + gd + gt)
    blob += b'\0' * (data_sector * 512 - len(blob))
    return bytes(blob + body)

v = pattern(5 * MB)
write('vmdk-sparse.raw', v); write('vmdk-sparse.vmdk', vmdk(v))
write('vmdk-deflate.raw', v); write('vmdk-deflate.vmdk', vmdk(v, compressed=True))
# a descriptor pointing to a flat extent and a sparse one
flat = pattern(2 * MB)
write('vmdk-split-f001.vmdk', flat)
sp = pattern(3 * MB)
write('vmdk-split-s002.vmdk', vmdk(sp))
open(os.path.join(out, 'vmdk-split.vmdk'), 'w').write('# Disk DescriptorFile\nversion=1\ncreateType="custom"\n\n# Extent description\nRW %d FLAT "vmdk-split-f001.vmdk" 0\nRW %d SPARSE "vmdk-split-s002.vmdk"\n' % (len(flat) // 512, len(sp) // 512))
write('vmdk-split.raw', bytes(flat + sp))
print('ok')
