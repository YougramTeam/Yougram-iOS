#import <BuildConfigExtra/BuildConfigExtra.h>

#include <mach-o/arch.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>

#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

#import <CommonCrypto/CommonCrypto.h>
#import <CommonCrypto/CommonDigest.h>

#import <PKCS/PKCS.h>

static NSData *sha1(NSData *data) {
    uint8_t digest[20];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    
    return [[NSData alloc] initWithBytes:digest length:20];
}

static NSString *telegramApplicationSecretKey = @"telegramApplicationSecretKey_v3";

static uint32_t funcSwap32(uint32_t input)
{
    return OSSwapBigToHostInt32(input);
}

static uint32_t funcNoSwap32(uint32_t input)
{
    return OSSwapLittleToHostInt32(input);
}

/*
 * Magic numbers used by Code Signing
 */
enum {
    kSecCodeMagicRequirement = 0xfade0c00,       /* single requirement */
    kSecCodeMagicRequirementSet = 0xfade0c01,    /* requirement set */
    kSecCodeMagicCodeDirectory = 0xfade0c02,     /* CodeDirectory */
    kSecCodeMagicEmbeddedSignature = 0xfade0cc0, /* single-architecture embedded signature */
    kSecCodeMagicDetachedSignature = 0xfade0cc1, /* detached multi-architecture signature */
    kSecCodeMagicEntitlement = 0xfade7171,       /* entitlement blob */
    
    kSecCodeMagicByte = 0xfa                     /* shared first byte */
};


/*
 * Structure of an embedded-signature SuperBlob
 */
typedef struct __BlobIndex {
    uint32_t type;                  /* type of entry */
    uint32_t offset;                /* offset of entry */
} CS_BlobIndex;

typedef struct __Blob {
    uint32_t magic;                 /* magic number */
    uint32_t length;                /* total length of SuperBlob */
} CS_Blob;

typedef struct __SuperBlob {
    CS_Blob blob;
    uint32_t count;                  /* number of index entries following */
    CS_BlobIndex index[];            /* (count) entries */
    /* followed by Blobs in no particular order as indicated by offsets in index */
} CS_SuperBlob;


/*
 * C form of a CodeDirectory.
 */
typedef struct __CodeDirectory {
    uint32_t magic;                 /* magic number (CSMAGIC_CODEDIRECTORY) */
    uint32_t length;                /* total length of CodeDirectory blob */
    uint32_t version;               /* compatibility version */
    uint32_t flags;                 /* setup and mode flags */
    uint32_t hashOffset;            /* offset of hash slot element at index zero */
    uint32_t identOffset;           /* offset of identifier string */
    uint32_t nSpecialSlots;         /* number of special hash slots */
    uint32_t nCodeSlots;            /* number of ordinary (code) hash slots */
    uint32_t codeLimit;             /* limit to main image signature range */
    uint8_t hashSize;               /* size of each hash in bytes */
    uint8_t hashType;               /* type of hash (cdHashType* constants) */
    uint8_t spare1;                 /* unused (must be zero) */
    uint8_t    pageSize;            /* log2(page size in bytes); 0 => infinite */
    uint32_t spare2;                /* unused (must be zero) */
    /* followed by dynamic content as located by offset fields above */
} CS_CodeDirectory;

static MTPKCS * _Nullable parseSignature(const char* buffer, size_t size) {
    if (buffer == NULL || size < sizeof(CS_SuperBlob)) {
        return nil;
    }

    CS_SuperBlob sb;
    memcpy(&sb, buffer, sizeof(CS_SuperBlob));
    if (OSSwapBigToHostInt32(sb.blob.magic) != kSecCodeMagicEmbeddedSignature) {
        return nil;
    }
    
    uint32_t count = OSSwapBigToHostInt32(sb.count);
    if (count > 1024) {
        return nil;
    }
    size_t headerSize = sizeof(CS_SuperBlob) + (size_t)count * sizeof(CS_BlobIndex);
    if (headerSize > size) {
        return nil;
    }
    
    for (uint32_t i = 0; i < count; i++) {
        CS_BlobIndex entry;
        memcpy(&entry, buffer + sizeof(CS_SuperBlob) + (size_t)i * sizeof(CS_BlobIndex), sizeof(CS_BlobIndex));
        uint32_t offset = OSSwapBigToHostInt32(entry.offset);
        if ((size_t)offset > size - sizeof(CS_Blob)) {
            continue;
        }
        
        CS_Blob blob;
        memcpy(&blob, buffer + offset, sizeof(CS_Blob));
        uint32_t blobLength = OSSwapBigToHostInt32(blob.length);
        
        if (OSSwapBigToHostInt32(blob.magic) == 0xfade0b01) // signature
        {
            if (blobLength > 8 && (size_t)blobLength <= size - (size_t)offset) {
                const unsigned char* message = (const unsigned char*)buffer + offset + 8;
                MTPKCS *result = [MTPKCS parse:message size:(blobLength - 8)];
                return result;
            }
        }
    }
    
    return nil;
}

static MTPKCS * _Nullable parseArch(const char* buffer, size_t size) {
    if (buffer == NULL || size < sizeof(struct mach_header)) {
        return nil;
    }

    uint32_t (*swap32)(uint32_t) = funcNoSwap32;
    uint32_t offset = 0;
    
    struct mach_header header;
    memcpy(&header, buffer, sizeof(struct mach_header));
    
    switch (header.magic) {
        case MH_CIGAM:
            swap32 = funcSwap32;
        case MH_MAGIC:
            offset += sizeof(struct mach_header);
            break;
        case MH_CIGAM_64:
            swap32 = funcSwap32;
        case MH_MAGIC_64:
            if (size < sizeof(struct mach_header_64)) {
                return nil;
            }
            offset += sizeof(struct mach_header_64);
            break;
        default:
            return nil;
    }
    
    uint32_t commandCount = swap32(header.ncmds);
    
    for (uint32_t i = 0; i < commandCount; i++) {
        if ((size_t)offset > size || size - (size_t)offset < sizeof(struct load_command)) {
            return nil;
        }
        struct load_command loadCommand;
        memcpy(&loadCommand, buffer + offset, sizeof(struct load_command));
        uint32_t commandSize = swap32(loadCommand.cmdsize);
        if (commandSize < sizeof(struct load_command) || (size_t)commandSize > size - (size_t)offset) {
            return nil;
        }
        
        uint32_t commandType = swap32(loadCommand.cmd);
        if (commandType == LC_CODE_SIGNATURE) {
            if (commandSize < sizeof(struct linkedit_data_command)) {
                return nil;
            }
            struct linkedit_data_command dataCommand;
            memcpy(&dataCommand, buffer + offset, sizeof(struct linkedit_data_command));
            uint32_t dataOffset = swap32(dataCommand.dataoff);
            uint32_t dataSize = swap32(dataCommand.datasize);
            if ((size_t)dataOffset > size || (size_t)dataSize > size - (size_t)dataOffset) {
                return nil;
            }
            
            return parseSignature(buffer + dataOffset, dataSize);
        }
        
        offset += commandSize;
    }
    
    return nil;
}

static MTPKCS * _Nullable parseFat(const char *buffer, size_t size) {
    if (buffer == NULL || size < sizeof(struct fat_header)) {
        return nil;
    }

    size_t offset = 0;
    struct fat_header fatHeader;
    memcpy(&fatHeader, buffer, sizeof(fatHeader));
    offset += sizeof(fatHeader);
    
    uint32_t archCount = OSSwapBigToHostInt32(fatHeader.nfat_arch);
    if (archCount > 64 || (size_t)archCount > (size - offset) / sizeof(struct fat_arch)) {
        return nil;
    }
    
    for (uint32_t i = 0; i < archCount; i++) {
        struct fat_arch arch;
        memcpy(&arch, buffer + offset, sizeof(arch));
        offset += sizeof(arch);
        
        uint32_t archOffset = OSSwapBigToHostInt32(arch.offset);
        uint32_t archSize = OSSwapBigToHostInt32(arch.size);
        if ((size_t)archOffset > size || (size_t)archSize > size - (size_t)archOffset) {
            continue;
        }
        
        MTPKCS *result = parseArch(buffer + archOffset, archSize);
        if (result != nil) {
            return result;
        }
    }
    
    return nil;
}

static MTPKCS * _Nullable parseMachO(const char* buffer, size_t size) {
    if (buffer == NULL || size < sizeof(uint32_t)) {
        return nil;
    }
    uint32_t magic = 0;
    memcpy(&magic, buffer, sizeof(uint32_t));
    
    if (magic == FAT_CIGAM || magic == FAT_MAGIC) {
        return parseFat(buffer, size);
    } else {
        return parseArch(buffer, size);
    }
}

static MTPKCS * _Nullable checkSignature(const char *filename) {
    if (filename == NULL) {
        return nil;
    }

    char *buffer = NULL;
    int fd = open(filename, O_RDONLY);
    if (fd == -1) {
        return nil;
    }
    
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) {
        close(fd);
        return nil;
    }
    
    buffer = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_FILE|MAP_PRIVATE, fd, 0);
    if (buffer == MAP_FAILED) {
        close(fd);
        return nil;
    }
    
    MTPKCS *result = parseMachO(buffer, (size_t)st.st_size);
    munmap(buffer, (size_t)st.st_size);
    close(fd);
    
    return result;
}

@implementation BuildConfigExtra

+ (NSDictionary * _Nonnull)signatureDict {
    NSMutableDictionary *dataDict = [[NSMutableDictionary alloc] init];
    MTPKCS *signature = checkSignature([[[NSBundle mainBundle] executablePath] UTF8String]);
    if (signature.issuerName != nil) {
        dataDict[@"issuerName"] = signature.issuerName;
    }
    if (signature.subjectName != nil) {
        dataDict[@"name"] = signature.subjectName;
    }
    if (signature.data != nil) {
        dataDict[@"data"] = [sha1(signature.data) base64EncodedStringWithOptions:0];
        dataDict[@"data1"] = [signature.data base64EncodedStringWithOptions:0];
    }
    return dataDict;
}

@end
