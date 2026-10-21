#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach-o/nlist.h>
#import <dlfcn.h>
#import "SpaceInterop.h"

// The bridged operation exists on Sequoia, but its submit function is a local
// Mach-O symbol. Read only the already-loaded image's symbol table; never patch
// memory, inject code, or modify another process. API discovery references:
// https://github.com/asmvik/yabai/blob/master/src/space_manager.c
// https://github.com/Hammerspoon/hammerspoon/pull/3889
typedef int64_t (*SubmitOperation)(void *);
@interface NSObject (RibbonSpaceOperation)
- (instancetype)initWithWindows:(NSArray *)windows spaceID:(uint64_t)space;
@end

static SubmitOperation submitFunction(void) {
    static SubmitOperation submit;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        submit = (SubmitOperation)dlsym(library, "SLSPerformAsynchronousBridgedWindowManagementOperation");
        if (submit) return;
        const char *wanted = "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation";
        for (uint32_t image = 0; image < _dyld_image_count(); image++) {
            const char *name = _dyld_get_image_name(image);
            if (!name || !strstr(name, "/SkyLight.framework/")) continue;
            const struct mach_header_64 *header = (const void *)_dyld_get_image_header(image);
            if (header->magic != MH_MAGIC_64) continue;
            const struct symtab_command *symbols = NULL;
            const struct segment_command_64 *linkedit = NULL;
            const uint8_t *cursor = (const uint8_t *)(header + 1);
            const uint8_t *end = cursor + header->sizeofcmds;
            for (uint32_t i = 0; i < header->ncmds && cursor + sizeof(struct load_command) <= end; i++) {
                const struct load_command *command = (const void *)cursor;
                if (command->cmdsize < sizeof(*command) || cursor + command->cmdsize > end) break;
                if (command->cmd == LC_SYMTAB && command->cmdsize >= sizeof(*symbols)) symbols = (const void *)command;
                if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(*linkedit)) {
                    const struct segment_command_64 *segment = (const void *)command;
                    if (!strncmp(segment->segname, SEG_LINKEDIT, sizeof(segment->segname))) linkedit = segment;
                }
                cursor += command->cmdsize;
            }
            if (!symbols || !linkedit) continue;
            intptr_t slide = _dyld_get_image_vmaddr_slide(image);
            uintptr_t base = slide + linkedit->vmaddr - linkedit->fileoff;
            const struct nlist_64 *table = (const void *)(base + symbols->symoff);
            const char *strings = (const void *)(base + symbols->stroff);
            for (uint32_t i = 0; i < symbols->nsyms; i++) {
                uint32_t offset = table[i].n_un.n_strx;
                if (offset >= symbols->strsize || !table[i].n_value || (table[i].n_type & N_TYPE) != N_SECT) continue;
                if (!strncmp(strings + offset, wanted, symbols->strsize - offset)) {
                    submit = (SubmitOperation)(slide + table[i].n_value);
                    return;
                }
            }
        }
    });
    return submit;
}

bool RDHasBridgedSpaceMove(void) {
    SubmitOperation submit = submitFunction();
    Class type = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    return submit != NULL && [type instancesRespondToSelector:@selector(initWithWindows:spaceID:)];
}
bool RDSubmitSpaceMove(uint32_t window, uint64_t space) {
    if (!RDHasBridgedSpaceMove()) return false;
    Class type = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    id operation = [[type alloc] initWithWindows:@[@(window)] spaceID:space];
    if (!operation) return false;
    submitFunction()((__bridge void *)operation);
#if !__has_feature(objc_arc)
    [operation release];
#endif
    // Submission is asynchronous. Swift verifies the eventual membership.
    return true;
}
