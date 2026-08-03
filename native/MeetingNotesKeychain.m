#import <Foundation/Foundation.h>
#import <Security/Security.h>

static NSString *const MeetingNotesKeychainService = @"com.local.meetingnotes.openai";
static NSString *const MeetingNotesKeychainAccount = @"default";
static OSStatus MeetingNotesLastKeychainStatus = errSecSuccess;

static NSMutableDictionary *MeetingNotesKeychainQuery(void) {
    return [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: MeetingNotesKeychainService,
        (__bridge id)kSecAttrAccount: MeetingNotesKeychainAccount,
    } mutableCopy];
}

int meeting_notes_keychain_get(unsigned char *buffer, size_t capacity, size_t *length) {
    @autoreleasepool {
        if (buffer == NULL || length == NULL || capacity == 0) {
            MeetingNotesLastKeychainStatus = errSecParam;
            return -1;
        }

        NSMutableDictionary *query = MeetingNotesKeychainQuery();
        query[(__bridge id)kSecReturnData] = @YES;
        query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

        CFTypeRef result = NULL;
        MeetingNotesLastKeychainStatus = SecItemCopyMatching(
            (__bridge CFDictionaryRef)query,
            &result
        );
        if (MeetingNotesLastKeychainStatus == errSecItemNotFound) {
            *length = 0;
            return 0;
        }
        if (MeetingNotesLastKeychainStatus != errSecSuccess || result == NULL) {
            *length = 0;
            return -1;
        }

        NSData *data = CFBridgingRelease(result);
        if (data.length > capacity) {
            MeetingNotesLastKeychainStatus = errSecBufferTooSmall;
            *length = data.length;
            return -1;
        }
        memcpy(buffer, data.bytes, data.length);
        *length = data.length;
        return 1;
    }
}

int meeting_notes_keychain_set(const unsigned char *secret, size_t length) {
    @autoreleasepool {
        if (secret == NULL || length == 0) {
            MeetingNotesLastKeychainStatus = errSecParam;
            return 0;
        }

        NSData *data = [NSData dataWithBytes:secret length:length];
        NSMutableDictionary *query = MeetingNotesKeychainQuery();
        NSDictionary *update = @{ (__bridge id)kSecValueData: data };
        MeetingNotesLastKeychainStatus = SecItemUpdate(
            (__bridge CFDictionaryRef)query,
            (__bridge CFDictionaryRef)update
        );
        if (MeetingNotesLastKeychainStatus == errSecItemNotFound) {
            query[(__bridge id)kSecValueData] = data;
            MeetingNotesLastKeychainStatus = SecItemAdd(
                (__bridge CFDictionaryRef)query,
                NULL
            );
        }
        return MeetingNotesLastKeychainStatus == errSecSuccess ? 1 : 0;
    }
}

int meeting_notes_keychain_delete(void) {
    @autoreleasepool {
        NSMutableDictionary *query = MeetingNotesKeychainQuery();
        MeetingNotesLastKeychainStatus = SecItemDelete((__bridge CFDictionaryRef)query);
        return MeetingNotesLastKeychainStatus == errSecSuccess ||
            MeetingNotesLastKeychainStatus == errSecItemNotFound ? 1 : 0;
    }
}

int meeting_notes_keychain_last_status(void) {
    return (int)MeetingNotesLastKeychainStatus;
}
