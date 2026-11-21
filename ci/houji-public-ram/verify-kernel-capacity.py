"""Verify that the final arm64e kernel contains the actual capacity entry."""
import hashlib
from pathlib import Path
import struct
import sys

ENTRY = b"_houji26_ufs_capacity_from_handoff"


def verify(data, name):
    magic, cpu, subtype, kind, count, command_bytes, _, _ = struct.unpack_from("<8I", data)
    if (magic, cpu, subtype & 0xffffff, kind) != (0xfeedfacf, 0x0100000c, 2, 2):
        raise ValueError("expected an arm64e Mach-O executable")
    cursor = 32
    end = cursor + command_bytes
    if end > len(data) or count > command_bytes // 8:
        raise ValueError("invalid Mach-O load command range")

    sections = []
    table = None
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, cursor)
        if size < 8 or cursor + size > end:
            raise ValueError("invalid Mach-O load command size")
        if command == 0x19:
            if size < 72:
                raise ValueError("short LC_SEGMENT_64")
            protection, section_count = struct.unpack_from("<II", data, cursor + 60)
            if 72 + section_count * 80 > size:
                raise ValueError("invalid Mach-O section list")
            for index in range(section_count):
                start = cursor + 72 + 80 * index
                section, segment, address, length, offset = struct.unpack_from("<16s16sQQI", data, start)
                sections.append((section.rstrip(b"\0"), segment.rstrip(b"\0"), address,
                                 length, offset, protection))
        elif command == 2:
            if size != 24 or table is not None:
                raise ValueError("invalid LC_SYMTAB")
            table = struct.unpack_from("<IIII", data, cursor + 8)
        cursor += size
    if table is None or cursor != end:
        raise ValueError("missing symbol table or incomplete load commands")
    symbols, count, strings, string_bytes = table
    if symbols + 16 * count > len(data) or strings + string_bytes > len(data):
        raise ValueError("symbol or string table outside the binary")

    for index in range(count):
        string, flags, section, _, value = struct.unpack_from("<IBBHQ", data, symbols + 16 * index)
        if flags & 0xe0 or flags & 0x0e != 0x0e or not 1 <= section <= len(sections):
            continue
        stop = string + len(name) + 1
        if stop > string_bytes or data[strings + string:strings + stop] != name + b"\0":
            continue
        section_name, segment, address, length, offset, protection = sections[section - 1]
        file_offset = offset + value - address
        if (section_name != b"__text" or not protection & 4 or value % 4 or
                value < address or value + 4 > address + length or file_offset + 4 > len(data)):
            raise ValueError("the capacity symbol is outside executable code")
        return segment.decode(), value
    raise ValueError(f"missing defined executable symbol {name.decode()}")


def main():
    path = Path(sys.argv[1])
    data = path.read_bytes()
    print(f"Kernel path {path}", flush=True)
    print(f"Kernel bytes {len(data)}", flush=True)
    print(f"Kernel SHA256 {hashlib.sha256(data).hexdigest()}", flush=True)
    try:
        segment, address = verify(data, ENTRY)
    except (ValueError, struct.error) as error:
        raise SystemExit(str(error)) from error
    print(f"PASS: {ENTRY.decode()} in {segment},__text at {address:#x}")


if __name__ == "__main__":
    main()
