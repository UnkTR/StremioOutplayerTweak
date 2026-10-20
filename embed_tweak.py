import sys
import lief


def inject(binary, dylib_path):
    binary.add_library(dylib_path)


def main():
    binary_path = sys.argv[1]
    dylib_path = sys.argv[2]
    parsed = lief.MachO.parse(binary_path)
    if isinstance(parsed, lief.MachO.FatBinary):
        for binary in parsed:
            inject(binary, dylib_path)
        parsed.write(binary_path)
    else:
        inject(parsed, dylib_path)
        parsed.write(binary_path)
    print(f"injected {dylib_path} into {binary_path}")


if __name__ == "__main__":
    main()
