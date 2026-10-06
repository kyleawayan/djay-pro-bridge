import tempfile
import unittest
from pathlib import Path
from extract_system_one_proto import check_destination, find_schema


def varint(value):
    out = bytearray()
    while value > 127:
        out.append((value & 127) | 128)
        value >>= 7
    return bytes(out) + bytes([value])


def blob(number, content):
    return varint(number << 3 | 2) + varint(len(content)) + content


def descriptor(field_number=1):
    field = blob(1, b'example') + b'\x18' + varint(field_number) + b'\x20\x01\x28\x08'
    message = blob(1, b'HybridModeMessage') + blob(2, field)
    return (blob(1, b'remote_host_screen_service_test.proto')
            + blob(2, b'remotehostscreen.v1') + blob(4, message) + blob(12, b'proto3'))


class ExtractorTests(unittest.TestCase):
    def test_identical_slices_are_deduplicated_and_offsets_retained(self):
        data = descriptor()
        found = find_schema(b'prefix\0' + data + b'\0padding\0' + data)
        self.assertEqual(found['data'], data)
        self.assertEqual(len(found['offsets']), 2)

    def test_conflicting_schemas_fail_instead_of_choosing_silently(self):
        with self.assertRaisesRegex(ValueError, 'Multiple distinct'):
            find_schema(descriptor(1) + b'\0' + descriptor(2))

    def test_stray_names_do_not_count_as_descriptors(self):
        with self.assertRaisesRegex(ValueError, 'No readable matching'):
            find_schema(b'remote_host_screen_service_test.proto\0proto3')

    def test_git_output_is_refused_before_creation(self):
        with tempfile.TemporaryDirectory(prefix='schema-extractor-test-') as directory:
            root = Path(directory)
            (root / '.git').mkdir()
            output = root / 'exports'
            with self.assertRaisesRegex(ValueError, 'outside Git'):
                check_destination(output)
            self.assertFalse(output.exists())

    def test_nonempty_output_is_not_overwritten(self):
        with tempfile.TemporaryDirectory(prefix='schema-extractor-test-') as directory:
            root = Path(directory)
            (root / 'keep.txt').write_text('example')
            with self.assertRaisesRegex(ValueError, 'not overwritten'):
                check_destination(root)
            self.assertEqual((root / 'keep.txt').read_text(), 'example')


if __name__ == '__main__':
    unittest.main()
