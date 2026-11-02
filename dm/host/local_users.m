// The built-in launchers and guest services use the same launch-time roster.
#import <Foundation/Foundation.h>
#include "local_users.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>

static dm_user_roster roster;
static char problem[256];
static int selected, locked;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static pthread_mutex_t selection_lock = PTHREAD_MUTEX_INITIALIZER;

int dm_users_prepare_file(const char *base_directory, const char *default_file) {
    const char *path = getenv("DM_USERS_FILE");
    if (!path) {
        struct stat st;
        if (lstat(default_file, &st) && errno == ENOENT) return 1;
        return setenv("DM_USERS_FILE", default_file, 1) == 0;
    }
    if (*path == '/' || !*path) return 1;
    char absolute[PATH_MAX];
    int n = snprintf(absolute, sizeof absolute, "%s/%s", base_directory, path);
    return n >= 0 && (size_t)n < sizeof absolute && setenv("DM_USERS_FILE", absolute, 1) == 0;
}

// Exact hex, with no sign, prefix or separator. Text is the high word followed by the low word.
static int parse_id(const char *s, dm_user_uid *uid) {
    if (!s || strlen(s) != 32) return 0;
    *uid = (dm_user_uid){0};
    for (int i = 0; i < 32; ++i) {
        unsigned c = (unsigned char)s[i], digit;
        if (c >= '0' && c <= '9') digit = c - '0';
        else if (c >= 'a' && c <= 'f') digit = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') digit = c - 'A' + 10;
        else return 0;
        int word = i < 16 ? 1 : 0;
        uid->v[word] = (uid->v[word] << 4) | digit;
    }
    return uid->v[0] || uid->v[1];
}

static int index_of(const dm_user_uid *uid) {
    if (uid) for (int i = 0; i < roster.count; ++i) {
        if (uid->v[0] == roster.users[i].uid.v[0] && uid->v[1] == roster.users[i].uid.v[1]) return i;
    }
    return -1;
}

static int fail(const char *reason) {
    snprintf(problem, sizeof problem, "%s", reason);
    return 0;
}

static int load_file(const char *path) {
    // An env.txt or an external frontend may name any path. Inspect the opened file;
    // a FIFO without a writer must not hang launch, and an oversized file needn't be parsed.
    int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        snprintf(problem, sizeof problem, "Cannot open DM_USERS_FILE: %s", strerror(errno));
        return 0;
    }
    struct stat st;
    char data[16385];
    size_t size = 0;
    int ok = !fstat(fd, &st) && S_ISREG(st.st_mode) && st.st_size < (off_t)sizeof data;
    while (ok && size < sizeof data) {
        ssize_t n = read(fd, data + size, sizeof data - size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { ok = n == 0; break; }
        size += (size_t)n;
    }
    close(fd);
    if (!ok || size == sizeof data) return fail("DM_USERS_FILE must be a readable regular file of at most 16 KiB");
    id doc = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:data length:size] options:0 error:nil];
    if (![doc isKindOfClass:[NSDictionary class]]) return fail("DM_USERS_FILE must contain a JSON object");
    id version = doc[@"version"], users = doc[@"users"];
    if (![version isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)version) == CFBooleanGetTypeID() ||
        ![version isEqual:@1]) return fail("Unsupported local user roster version (expected 1)");
    if (![users isKindOfClass:[NSArray class]] || [users count] < 1 || [users count] > DM_MAX_LOCAL_USERS)
        return fail("The local user roster must contain 1 to 8 users");
    for (id row in users) {
        if (![row isKindOfClass:[NSDictionary class]]) return fail("Each local user must be a JSON object");
        NSString *key = row[@"id"], *name = row[@"nickname"];
        dm_local_user *user = &roster.users[roster.count];
        if (![key isKindOfClass:[NSString class]] || key.length != 32 || !parse_id(key.UTF8String, &user->uid))
            return fail("A local user ID must be 32 nonzero-valued hexadecimal digits");
        if (index_of(&user->uid) >= 0) return fail("The local user roster contains a duplicate ID");
        snprintf(user->id, sizeof user->id, "%016llx%016llx", (unsigned long long)user->uid.v[1], (unsigned long long)user->uid.v[0]);
        if (![name isKindOfClass:[NSString class]] || !name.length ||
            [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >= sizeof user->nickname ||
            [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
            return fail("A local nickname must be 1 to 32 UTF-8 bytes and contain no control characters");
        if (![name getCString:user->nickname maxLength:sizeof user->nickname encoding:NSUTF8StringEncoding])
            return fail("Invalid UTF-8 nickname");
        ++roster.count;
    }
    return 1;
}

static void load_once(void) {
    @autoreleasepool {
        const char *path = getenv("DM_USERS_FILE"), *requested = getenv("DM_USER_ID");
        roster.configured = path != NULL;
        if (path) {
            if (!load_file(path)) { roster.count = 0; return; }
        } else {
            dm_local_user *user = &roster.users[0];
            parse_id(DM_LEGACY_USER_ID, &user->uid);
            strlcpy(user->id, DM_LEGACY_USER_ID, sizeof user->id);
            const char *nick = getenv("DM_NICK");
            if (!nick || ![NSString stringWithUTF8String:nick]) nick = "Player";
            size_t bytes = strnlen(nick, 32);
            while (bytes && ((unsigned char)nick[bytes] & 0xc0) == 0x80) --bytes;
            memcpy(user->nickname, nick, bytes);
            roster.count = 1;
        }
        if (requested) {
            dm_user_uid uid;
            selected = parse_id(requested, &uid) ? index_of(&uid) : -1;
            if (selected < 0) {
                fail("DM_USER_ID does not identify a user in this roster");
                roster.count = 0;
            }
            locked = 1;
        }
    }
}

const dm_user_roster *dm_users(void) { pthread_once(&once, load_once); return &roster; }
int dm_users_count(void) { return dm_users()->count; }
const char *dm_users_error(void) { dm_users(); return *problem ? problem : NULL; }

static const dm_local_user *at(int index) {
    return index >= 0 && index < dm_users_count() ? &roster.users[index] : NULL;
}

const dm_local_user *dm_user_find(const dm_user_uid *uid) {
    dm_users();
    return at(index_of(uid));
}

const char *dm_users_id_at(int index) { const dm_local_user *u = at(index); return u ? u->id : NULL; }
const char *dm_users_nickname_at(int index) { const dm_local_user *u = at(index); return u ? u->nickname : NULL; }

int dm_users_selected_index(void) {
    if (!dm_users_count()) return -1;
    pthread_mutex_lock(&selection_lock);
    int i = selected;
    pthread_mutex_unlock(&selection_lock);
    return i;
}

const dm_local_user *dm_selected_user(void) { return at(dm_users_selected_index()); }

int dm_users_selection_locked(void) {
    dm_users();
    pthread_mutex_lock(&selection_lock);
    int result = locked;
    pthread_mutex_unlock(&selection_lock);
    return result;
}

int dm_users_select_index(int index) {
    const dm_local_user *u = at(index);
    if (!u) return 0;
    pthread_mutex_lock(&selection_lock);
    int ok = !locked && !setenv("DM_USER_ID", u->id, 1);
    if (ok) selected = index;
    pthread_mutex_unlock(&selection_lock);
    return ok;
}

int dm_users_begin_session(void) {
    if (!dm_users_count()) return 0;
    pthread_mutex_lock(&selection_lock);
    locked = 1;
    pthread_mutex_unlock(&selection_lock);
    return 1;
}

int dm_users_write_json(FILE *out) {
    @autoreleasepool {
        const dm_local_user *active = dm_selected_user();
        if (!active) return 0;
        NSMutableArray *users = [NSMutableArray array];
        for (int i = 0; i < roster.count; ++i) {
            const dm_local_user *u = &roster.users[i];
            [users addObject:@{@"id": @(u->id), @"nickname": @(u->nickname)}];
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"version": @1, @"users": users, @"selected": @(active->id)}
                                                       options:0 error:nil];
        return json && fwrite(json.bytes, 1, json.length, out) == json.length && fputc('\n', out) != EOF && !fflush(out);
    }
}
