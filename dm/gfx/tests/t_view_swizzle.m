// Channel mapping of registered textures (tex_by_id): the descriptor's swizzle composed with the format's own mapping, read back from the GPU through the production lookup.
// The RGB565 family's red / blue swap is for uploaded textures only; a texture Metal cleared reads as cleared, and an image slot gets a writable view without the mapping (img_fit)
#include "../nvn/nvn_mtl.m"
uint64_t g_t0_ns;
int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, fails;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s\n", msg); } } while (0)
static id<MTLComputePipelineState> pipe_of(NSString *src, NSString *name) {
    NSError *error = nil; id<MTLLibrary> library = [g_dev newLibraryWithSource:src options:nil error:&error];
    id<MTLComputePipelineState> p = [g_dev newComputePipelineStateWithFunction:[library newFunctionWithName:name] error:&error];
    CHECK(p != nil, "pipeline created");
    return p;
}
static void run2(id<MTLComputePipelineState> p, id<MTLTexture> t, id<MTLBuffer> out) {
    id<MTLCommandBuffer> command = q_cb(); id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    [encoder setComputePipelineState:p]; [encoder setTexture:t atIndex:0]; if (out) [encoder setBuffer:out offset:0 atIndex:0];
    [encoder dispatchThreads:MTLSizeMake(2, 1, 1) threadsPerThreadgroup:MTLSizeMake(2, 1, 1)];
    [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
    CHECK(command.status == MTLCommandBufferStatusCompleted, "GPU work completed");
}
static void read_check(int tid, id<MTLTexture> view, const float expected[8], float tol) {   // the two texels as the shader reads them
    static id<MTLComputePipelineState> p;
    if (!p) p = pipe_of(@"#include <metal_stdlib>\nusing namespace metal;\nkernel void sample_packed(texture2d<float, access::read> t [[texture(0)]], device float4 *out [[buffer(0)]], uint i [[thread_position_in_grid]]) { out[i] = t.read(uint2(i, 0)); }\n", @"sample_packed");
    id<MTLBuffer> output = [g_dev newBufferWithLength:32 options:MTLResourceStorageModeShared];
    run2(p, view, output);
    float *actual = output.contents;
    for (int i = 0; i < 8; i++) { if (fabsf(actual[i] - expected[i]) > tol) fprintf(stderr, "case %d component %d: got %g expected %g\n", tid, i, actual[i], expected[i]); CHECK(fabsf(actual[i] - expected[i]) <= tol, "sampled channel matches NVN format and mapping"); }
}
// uploaded: as tex_mtl leaves a texture uploaded from guest memory, an NvPkg in the serial table, clean since its upload (no guest write since, so its pages are not looked at), its bits in
// Metal's order as the upload repacks them
static void swizzle_case(int tid, int format, int view_format, int uploaded, const void *pixels, unsigned bytes, const uint8_t *builder, const uint8_t *mapping, const float expected[8]) {
    tex_t t = {.magic=MAGIC('T','E','X',0), .serial=98000+(unsigned)tid};
    t.d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=format, .width=2, .height=1, .depth=1, .levels=1, .samples=1};
    if (builder) { t.set_swz = 1; for (int c = 0; c < 4; c++) t.swz |= (uint16_t)builder[c] << (3 * c); }
    MTLTextureDescriptor *d = tex_desc(&t, 1); d.storageMode = MTLStorageModeShared;
    id<MTLTexture> base = [g_dev newTextureWithDescriptor:d];
    CHECK(base != nil, "packed texture created");
    uint8_t host[16]; memcpy(host, pixels, bytes);   // an upload stores packed formats in Metal's order (pkg_upload_)
    if (uploaded && packed16_kind(format)) packed16_rows(host, bytes, 1, 1, bytes, bytes, packed16_kind(format));
    [base replaceRegion:MTLRegionMake2D(0, 0, 2, 1) mipmapLevel:0 withBytes:host bytesPerRow:bytes];
    if (uploaded) { t.has_layout = 1; t.mem = (uint8_t *)pixels; NvPkg *pk = [NvPkg new]; pk->tex = base; pk->span = pixels; pk->seen = nvn_dirty_now(); serial_put(t.serial, pk); }
    else serial_put(t.serial, base);
    view_t v = {0}; if (mapping) { v.set_swizzle = 1; memcpy(v.swz, mapping, 4); }
    if (view_format) { v.set_format = 1; v.format = view_format; }
    mtl_reg_tex(tid, &t, mapping || view_format ? &v : NULL);
    os_unfair_lock_lock(&g_rmu);
    id<MTLTexture> view = tex_by_id(tid);
    CHECK(view != nil, "registered view created");
    CHECK(tex_by_id(tid) == view, "cached view retained");
    os_unfair_lock_unlock(&g_rmu);
    read_check(tid, view, expected, 0.001f);
}
// What Metal itself wrote into a packed texture is in Metal's order: a clear to red reads red, with no swap
static void cleared_case(int tid, int format) {
    tex_t t = {.magic=MAGIC('T','E','X',0), .serial=98000+(unsigned)tid};
    t.d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=format, .width=2, .height=1, .depth=1, .levels=1, .samples=1};
    id<MTLTexture> base = [g_dev newTextureWithDescriptor:tex_desc(&t, 0)];
    CHECK(base != nil && (base.usage & MTLTextureUsageRenderTarget), "render target created");
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = base; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1);
    id<MTLCommandBuffer> command = q_cb(); [[command renderCommandEncoderWithDescriptor:rp] endEncoding]; [command commit]; [command waitUntilCompleted];
    serial_put(t.serial, base);
    mtl_reg_tex(tid, &t, NULL);
    os_unfair_lock_lock(&g_rmu); id<MTLTexture> view = tex_by_id(tid); os_unfair_lock_unlock(&g_rmu);
    CHECK(view == base, "a cleared packed texture needs no view");
    read_check(tid, view, (const float[8]){1,0,0,1, 1,0,0,1}, 0.001f);
}
// An RGBX8 image texture: sampled through the swizzled view (alpha 1), which Metal makes read-only; the image slot's view (img_fit) is writable, without the mapping, and stores what the shader wrote
static void image_case(int tid) {
    tex_t t = {.magic=MAGIC('T','E','X',0), .serial=98000+(unsigned)tid};
    t.d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_RGBX8, .width=2, .height=1, .depth=1, .levels=1, .samples=1, .flags=NVN_TEXTURE_FLAGS_IMAGE};
    MTLTextureDescriptor *d = tex_desc(&t, 0); d.storageMode = MTLStorageModeShared;
    id<MTLTexture> base = [g_dev newTextureWithDescriptor:d];
    CHECK(base != nil && (base.usage & MTLTextureUsageShaderWrite), "image texture created");
    serial_put(t.serial, base);
    mtl_reg_tex(tid, &t, NULL);
    os_unfair_lock_lock(&g_rmu);
    id<MTLTexture> view = tex_by_id(tid); uint64_t rid = 0, rid2 = 0;
    CHECK(view != base && !(view.usage & MTLTextureUsageShaderWrite), "the sampled view is swizzled and read-only");
    id<MTLTexture> img = img_fit(tid, view, NVN_DPF_FLOAT, &rid);
    MTLTextureSwizzleChannels s = img.swizzle;
    CHECK(img && (img.usage & MTLTextureUsageShaderWrite) && rid == img.gpuResourceID._impl, "the image slot gets a writable view");
    CHECK(s.red == MTLTextureSwizzleRed && s.green == MTLTextureSwizzleGreen && s.blue == MTLTextureSwizzleBlue && s.alpha == MTLTextureSwizzleAlpha, "the image view has no channel mapping");
    CHECK(img_fit(tid, view, NVN_DPF_FLOAT, &rid2) == img && rid2 == rid, "the image view is kept for the next bind");
    os_unfair_lock_unlock(&g_rmu);
    run2(pipe_of(@"#include <metal_stdlib>\nusing namespace metal;\nkernel void store(texture2d<float, access::write> t [[texture(0)]], uint i [[thread_position_in_grid]]) { t.write(float4(0.25, 0.5, 0.75, 0.125), uint2(i, 0)); }\n", @"store"), img, nil);
    uint8_t px[8]; [base getBytes:px bytesPerRow:8 fromRegion:MTLRegionMake2D(0, 0, 2, 1) mipmapLevel:0];
    for (int i = 0; i < 8; i++) CHECK(abs((int)px[i] - (int[4]){64, 128, 191, 32}[i % 4]) <= 1, "the image write is stored as written");
    read_check(tid, view, (const float[8]){px[0]/255.f, px[1]/255.f, px[2]/255.f, 1, px[4]/255.f, px[5]/255.f, px[6]/255.f, 1}, 0.001f);
}
// A plain texture filled once from its pool (tex_init_fill): guest bits uploaded in Metal's order, so it reads right with no swap, and a later Metal render into part of it
// leaves the rest as uploaded (GitHub issue #183: Tears of the Kingdom's Depths walls). The guest storage keeps the guest's bits
static void init_fill_case(int tid, int format, int pool_flags) {
    tex_t t = {.magic=MAGIC('T','E','X',0), .serial=98000+(unsigned)tid};
    pool_t pool = {.magic=MAGIC('P','O','O','L'), .flags=pool_flags | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    t.d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=format, .width=2, .height=1, .depth=1, .levels=1, .samples=1};
    nvn_tex_layout(&t.d, &t.L); t.mem = calloc(1, t.L.size); t.pool = &pool; pool.mem = t.mem; pool.size = t.L.size;
    int b565 = format == NVN_FORMAT_RGB565 || format == NVN_FORMAT_BGR565;
    uint16_t pixels[2] = {format == NVN_FORMAT_RGBA4 ? 0xf00f : b565 ? 0x001f : 0x801f, format == NVN_FORMAT_RGBA4 ? 0x0f00 : b565 ? 0xf800 : 0x7c00}, kept[2] = {0};   // red, then blue (alpha 1 / 0 where the format has it)
    CHECK(nvn_swizzle(&t.d, 0, 0, pixels, 4, t.mem) == 0, "guest texels swizzled");
    g_sub_thread = pthread_self(); atomic_store(&g_sub_thread_set, 1);
    id<MTLTexture> base = [g_dev newTextureWithDescriptor:tex_desc(&t, 0)];
    CHECK(tex_init_fill(&t, base), "initial fill from the pool");
    up_flush(); mtl_finish_gpu();
    serial_put(t.serial, base); mtl_reg_tex(tid, &t, NULL);
    os_unfair_lock_lock(&g_rmu); id<MTLTexture> view = tex_by_id(tid); os_unfair_lock_unlock(&g_rmu);
    float want[8] = {1,0,0,1, 0,0,1, format == NVN_FORMAT_RGB5A1 || format == NVN_FORMAT_RGBA4 ? 0 : 1};
    if (format == NVN_FORMAT_BGR565) { want[0] = want[6] = 0; want[2] = want[4] = 1; }
    read_check(tid, view, want, 0.001f);
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nvertex float4 v(uint i [[vertex_id]]) { return float4(i == 1 ? 3 : -1, i == 2 ? 3 : -1, 0, 1); }\nfragment float4 f() { return float4(0, 1, 0, 1); }\n" options:nil error:nil];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"v"]; pd.fragmentFunction = [lib newFunctionWithName:@"f"]; pd.colorAttachments[0].pixelFormat = base.pixelFormat;
    id<MTLRenderPipelineState> p = [g_dev newRenderPipelineStateWithDescriptor:pd error:nil];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    // serial_put retains base in a C hash, released by mtl_tex_release below; the analyzer cannot follow that ownership through the hash.
    // NOLINTNEXTLINE(clang-analyzer-osx.cocoa.RetainCount)
    rp.colorAttachments[0].texture = base; rp.colorAttachments[0].loadAction = MTLLoadActionLoad; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> command = q_cb(); id<MTLRenderCommandEncoder> e = [command renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:p]; [e setScissorRect:(MTLScissorRect){0, 0, 1, 1}]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
    [command commit]; [command waitUntilCompleted];
    CHECK(p && command.status == MTLCommandBufferStatusCompleted, "partial render completed");
    want[0] = want[2] = 0; want[1] = want[3] = 1;   // texel 0 drawn green, texel 1 as uploaded
    read_check(tid, view, want, 0.001f);
    CHECK(nvn_deswizzle(&t.d, 0, 0, t.mem, kept, 4) == 0 && !memcmp(kept, pixels, 4), "guest storage keeps the guest's bits");
    mtl_reg_tex(tid, NULL, NULL);
    mtl_tex_release(&t);
    free(t.mem);
}
// In-place linear textures keep guest bytes in their MTLBuffer: compose the format mapping with the game's BGR mapping, without repacking or modifying the pool.
static void rgba4_linear_case(int tid, int bgr) {
    const uint16_t pixels[2] = {0x8421, 0x0f00};
    tex_t t = {.magic=MAGIC('T','E','X',0), .serial=98000+(unsigned)tid};
    t.d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_RGBA4, .width=2, .height=1, .depth=1, .levels=1, .samples=1};
    if (bgr) { t.set_swz = 1; t.swz = NVN_SWZ_B | NVN_SWZ_G << 3 | NVN_SWZ_R << 6 | NVN_SWZ_A << 9; }
    id<MTLBuffer> buffer = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    memcpy(buffer.contents, pixels, sizeof pixels);
    MTLTextureDescriptor *d = tex_desc(&t, 1); d.storageMode = MTLStorageModeShared;
    id<MTLTexture> base = [buffer newTextureWithDescriptor:d offset:0 bytesPerRow:256];
    CHECK(base != nil && base.buffer == buffer, "RGBA4 linear texture shares guest bytes");
    // serial_put retains base in a C hash, released by mtl_tex_release below; the analyzer cannot follow that ownership through the hash.
    // NOLINTNEXTLINE(clang-analyzer-osx.cocoa.RetainCount)
    serial_put(t.serial, base); mtl_reg_tex(tid, &t, NULL);
    os_unfair_lock_lock(&g_rmu); id<MTLTexture> view = tex_by_id(tid); os_unfair_lock_unlock(&g_rmu);
    const float rgba[8] = {1/15.f,2/15.f,4/15.f,8/15.f, 0,0,1,0};
    const float bgra[8] = {4/15.f,2/15.f,1/15.f,8/15.f, 1,0,0,0};
    read_check(tid, view, bgr ? bgra : rgba, .001f);
    CHECK(!memcmp(buffer.contents, pixels, sizeof pixels), "sampling an RGBA4 linear texture preserves guest bytes");
    mtl_reg_tex(tid, NULL, NULL);
    mtl_tex_release(&t);
}
static void finish_views(void) { CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "format-view GPU submission completed"); }
static void reinterpret_case(int tid, int inverse) {
    tex_t t = {.magic=MAGIC('T','E','X',0), .serial=99000+(unsigned)tid};
    t.d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=inverse ? NVN_FORMAT_R16 : NVN_FORMAT_RGBA4, .width=2, .height=1, .depth=1, .levels=1, .samples=1};
    MTLTextureDescriptor *d = tex_desc(&t, 0); d.storageMode = MTLStorageModeShared;
    id<MTLTexture> base = [g_dev newTextureWithDescriptor:d]; res_add(base);
    uint16_t guest[2] = {0x8421, 0x0f00}, host[2]; memcpy(host, guest, sizeof host);
    if (!inverse) packed16_rows((uint8_t *)host, 4, 1, 1, 4, 4, 4);
    [base replaceRegion:MTLRegionMake2D(0,0,2,1) mipmapLevel:0 withBytes:host bytesPerRow:4]; serial_put(t.serial, base);
    view_t v = {.set_format=1, .format=inverse ? NVN_FORMAT_RGBA4 : NVN_FORMAT_R16}; mtl_reg_tex(tid, &t, &v);
    mtl_sub_begin(); os_unfair_lock_lock(&g_rmu); id<MTLTexture> view = tex_by_id(tid); os_unfair_lock_unlock(&g_rmu); finish_views();
    CHECK(view != base && packed16_canonical(view) == base, "reinterpretation keeps its canonical backing identity");
    read_check(tid, view, inverse ? (float[8]){1/15.f,2/15.f,4/15.f,8/15.f,0,0,1,0} : (float[8]){0x8421/65535.f,0,0,1,0x0f00/65535.f,0,0,1}, .001f);
    // A GPU clear updates the same base object; the cached resource ID must subsequently read the new guest bytes.
    p_clear_tex c = {.tex=&t, .r={0,0,0,2,1,1}, .mask=15}; c.c.f[0]=1; c.c.f[3]=1;
    mtl_sub_begin(); clear_tex(&c); packed16_prepare(NULL, 0); finish_views();
    read_check(tid, view, inverse ? (float[8]){1,1,1,1,1,1,1,1} : (float[8]){0xf00f/65535.f,0,0,1,0xf00f/65535.f,0,0,1}, .001f);
    if (!inverse) {
        nvn_tex_layout(&t.d,&t.L); t.mem=calloc(1,t.L.size);
        uint16_t changed[2]={0x2468,0x1357}; CHECK(!nvn_swizzle(&t.d,0,0,changed,4,t.mem),"CPU replacement bytes swizzled");
        mtl_sub_begin(); id<MTLTexture> reused=pkg_upload_(&t,NULL,base,base.usage); CHECK(reused==base,"CPU upload reuses the existing physical backing");
        packed16_prepare(NULL,0);finish_views();
        read_check(tid,view,(float[8]){0x2468/65535.f,0,0,1,0x1357/65535.f,0,0,1},.001f);free(t.mem);t.mem=NULL;
    }
    // serial_put retains base in the C serial cache; mtl_tex_release below deletes that entry and retires its residency after the GPU fence.
    // NOLINTNEXTLINE(clang-analyzer-osx.cocoa.RetainCount)
    mtl_reg_tex(tid, NULL, NULL); mtl_tex_release(&t);
}
static void reinterpret_range_case(int tid) {
    tex_t t = {.magic=MAGIC('T','E','X',0), .serial=99000+(unsigned)tid};
    pool_t owner = {.magic=MAGIC('P','O','O','L')}; t.pool=&owner;
    t.d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D_ARRAY, .format=NVN_FORMAT_RGBA4, .width=4, .height=2, .depth=2, .levels=2, .samples=1};
    MTLTextureDescriptor *d=tex_desc(&t,0); d.storageMode=MTLStorageModeShared; id<MTLTexture> base=[g_dev newTextureWithDescriptor:d]; res_add(base);
    uint16_t host[8]; for (int i=0;i<8;i++) host[i]=0x1248;
    for (NSUInteger lv=0;lv<2;lv++) for (NSUInteger sl=0;sl<2;sl++) [base replaceRegion:MTLRegionMake2D(0,0,4>>lv,2>>lv) mipmapLevel:lv slice:sl withBytes:host bytesPerRow:(4>>lv)*2 bytesPerImage:(4>>lv)*(2>>lv)*2];
    serial_put(t.serial,base);
    view_t v={.set_format=1,.format=NVN_FORMAT_R16,.set_levels=1,.base_level=1,.nlevels=1,.set_layers=1,.min_layer=1,.nlayers=1,.set_target=1,.target=NVN_TEXTURE_TARGET_2D};
    mtl_reg_tex(tid,&t,&v);
    mtl_sub_begin(); os_unfair_lock_lock(&g_rmu); id<MTLTexture> view=tex_by_id(tid); os_unfair_lock_unlock(&g_rmu); finish_views();
    CHECK(view.width==2 && view.height==1 && view.mipmapLevelCount==1,"format view keeps requested mip and layer range");
    read_check(tid,view,(float[8]){0x8421/65535.f,0,0,1,0x8421/65535.f,0,0,1},.001f);
    p_clear_tex c={.tex=&t,.view=v,.has_view=1,.r={1,0,0,1,1,1},.mask=1}; c.c.f[0]=0x1357/65535.f;
    mtl_sub_begin(); clear_tex(&c); finish_views();
    for (NSUInteger lv=0;lv<2;lv++) for (NSUInteger sl=0;sl<2;sl++) {
        uint16_t got[8]={0}; [base getBytes:got bytesPerRow:(4>>lv)*2 bytesPerImage:(4>>lv)*(2>>lv)*2 fromRegion:MTLRegionMake2D(0,0,4>>lv,2>>lv) mipmapLevel:lv slice:sl];
        for (NSUInteger i=0;i<(4>>lv)*(2>>lv);i++) CHECK(got[i]==(lv==1 && sl==1 && i==1 ? 0x7531 : 0x1248),"partial R16 clear copies back only its selected guest texels");
    }
    // An unbound descriptor must not close an unrelated encoder or refresh a representation.
    NvProg *unrelated=[NvProg new]; mtl_sub_begin();
    MTL4RenderPassDescriptor *rp=[MTL4RenderPassDescriptor new]; rp.colorAttachments[0].texture=base; rp.colorAttachments[0].loadAction=MTLLoadActionLoad; rp.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTL4RenderCommandEncoder> en=enc_r_begin(rp); g_enc=en; uint64_t epoch=g_p16_epoch;
    packed16_prepare(unrelated,0x1f); CHECK(g_enc==en && g_p16_epoch==epoch,"unused reinterpretation does not split an unrelated render pass");
    g_enc=nil; enc_r_end(en); finish_views();
    treg_drop_pool_views(&owner); CHECK(!atomic_load(&g_p16_id_count),"pool finalization removes reinterpretation IDs");
    CHECK(!atomic_load(&g_p16_count),"pool finalization releases representation shadows");
    mtl_reg_tex(tid,NULL,NULL); mtl_tex_release(&t);
}
static void reinterpret_image_case(int tid, int implicit, int packaged) {
    tex_t t={.magic=MAGIC('T','E','X',0),.serial=99000+(unsigned)tid};
    int volume=packaged==2;pool_t pool={.magic=MAGIC('P','O','O','L'),.flags=NVN_MEMORY_POOL_FLAGS_CPU_CACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    t.d=(nvn_texdesc){.target=volume?NVN_TEXTURE_TARGET_3D:NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA4,.width=2,.height=1,.depth=volume?2:1,.levels=1,.samples=1,.flags=NVN_TEXTURE_FLAGS_IMAGE};
    MTLTextureDescriptor *d=tex_desc(&t,0);d.storageMode=MTLStorageModeShared;id<MTLTexture> base=[g_dev newTextureWithDescriptor:d];res_add(base);
    uint16_t px[4]={0x1248,0x00f0,0x1248,0x00f0};
    if(volume)[base replaceRegion:MTLRegionMake3D(0,0,0,2,1,2) mipmapLevel:0 slice:0 withBytes:px bytesPerRow:4 bytesPerImage:4];
    else [base replaceRegion:MTLRegionMake2D(0,0,2,1) mipmapLevel:0 withBytes:px bytesPerRow:4];
    if (packaged) {
        t.has_layout=1;nvn_tex_layout(&t.d,&t.L);t.mem=calloc(1,t.L.size);t.pool=&pool;pool.mem=t.mem;pool.size=t.L.size;
        uint16_t guest[4]={0x8421,0x0f00,0x8421,0x0f00};CHECK(!nvn_swizzle(&t.d,0,0,guest,4,t.mem),"packaged image guest bytes seeded");
        NvPkg *pk=[NvPkg new];pk->tex=base;pk->span=t.mem;pk->seen=pk->stamp=nvn_dirty_now();serial_put(t.serial,pk);
    } else serial_put(t.serial,base);
    // serial_put retains pk in the C serial cache until mtl_tex_release below; NvPkg dealloc removes base from residency and ARC releases it.
    // NOLINTNEXTLINE(clang-analyzer-osx.cocoa.RetainCount)
    view_t v={.set_format=1,.format=NVN_FORMAT_R16UI};mtl_reg_image(tid,&t,implicit?NULL:&v);
    mtl_sub_begin();os_unfair_lock_lock(&g_rmu);id<MTLTexture> sampled=tex_by_id(tid);uint64_t prepared_rid;
    if (implicit) CHECK(img_fit(tid,sampled,NVN_DPF_UINT,&prepared_rid)!=nil,"image-class representation prepared before encoder opens");
    os_unfair_lock_unlock(&g_rmu);finish_views();
    nvn_rbind binding={.kind=NVN_RB_IMG,.dpf=NVN_DPF_UINT,.dtt=volume?MTLTextureType3D:MTLTextureType2D,.rw=1};uint64_t rid;int real;
    NSString *source=volume ? @"#include <metal_stdlib>\nusing namespace metal;\nkernel void put(texture3d<uint,access::write> t [[texture(0)]],uint i [[thread_position_in_grid]]) { t.write(uint4(i?0x2468:0x1357),uint3(i,0,1)); }\n" : @"#include <metal_stdlib>\nusing namespace metal;\nkernel void put(texture2d<uint,access::write> t [[texture(0)]],uint i [[thread_position_in_grid]]) { t.write(uint4(i?0x2468:0x1357),uint2(i,0)); }\n";
    id<MTLComputePipelineState> ps=pipe_of(source,@"put");
    NvShader *cs=[NvShader new];cs->stage=5;cs->rf.nb=1;cs->rf.b[0]=binding;NvProg *pr=[NvProg new];pr->sh[5]=cs;S.img[5][0]=(uint64_t)tid;
    mtl_sub_begin();image_prepare(pr,1u<<5);id<MTL4ComputeCommandEncoder> ce=dispatch_enc();enc_c_pso(ce,ps);
    packed16_written();uint64_t bind_epoch=g_p16_epoch;   // an unrelated helper/upload invalidated the conservative clock after preparation
    os_unfair_lock_lock(&g_rmu);id<MTLTexture> image=img_binding(tid,&binding,&rid,&real);os_unfair_lock_unlock(&g_rmu);
    CHECK(g_blit==ce && g_p16_epoch==bind_epoch,"late image binding marks writes without refreshing or replacing the guest pipeline");
    CHECK(real && image.pixelFormat==MTLPixelFormatR16Uint && (image.usage&MTLTextureUsageShaderWrite),"valid R16 writable image view uses guest bits");
    [g_ct setTexture:image.gpuResourceID atIndex:0];enc_c_dispatch(ce,MTLSizeMake(1,1,1),MTLSizeMake(2,1,1));packed16_views_flush();finish_views();
    if(volume)[base getBytes:px bytesPerRow:4 bytesPerImage:4 fromRegion:MTLRegionMake3D(0,0,0,2,1,2) mipmapLevel:0 slice:0];
    else [base getBytes:px bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,2,1) mipmapLevel:0];
    int z=volume?2:0;CHECK(px[z]==0x7531 && px[z+1]==0x8642,"R16 image stores reverse-convert back to packed canonical storage");
    if(volume)CHECK(px[0]==0x1248 && px[1]==0x00f0,"3D image store preserves the other depth plane");
    CHECK(packed16_canonical(image)==base,"writable alias retains the canonical identity");
    if(packaged) {
        uint16_t got[4]={0};NVNcopyRegion region={0,0,0,2,1,volume?2:1};mtl_read_texels(&t,0,0,&region,(uint8_t *)got,4,4);
        CHECK(got[z]==0x1357 && got[z+1]==0x2468,"packaged image ReadTexels sees shader writes after the fence");
        CHECK(!nvn_deswizzle(&t.d,0,0,t.mem,got,4) && got[z]==0x1357 && got[z+1]==0x2468,"packaged image guest storage holds shader writes");
        if(volume)CHECK(got[0]==0x8421 && got[1]==0x0f00,"3D storage mirroring preserves the other depth plane");
    }
    // A representation reached without a registered format view must prepare without an index-set loop.
    mtl_reg_tex(tid,NULL,NULL);g_p16_ids=nil;mtl_sub_begin();packed16_prepare(NULL,0);finish_views();
    mtl_tex_release(&t);CHECK(!atomic_load(&g_p16_count),"texture finalization releases its representation");free(t.mem);S.img[5][0]=0;
}
int main(void) { @autoreleasepool {
    mtl_init();
    uint16_t pixels[2] = {0x001f, 0xf800};
    uint8_t rgb1[4] = {NVN_SWZ_R, NVN_SWZ_G, NVN_SWZ_B, NVN_SWZ_ONE};
    uint8_t map[4] = {NVN_SWZ_B, NVN_SWZ_R, NVN_SWZ_ONE, NVN_SWZ_ZERO};
    float rgb[8] = {1,0,0,1, 0,0,1,1};
    float bgr[8] = {0,0,1,1, 1,0,0,1};
    float composed[8] = {0,1,1,0, 1,0,1,0};
    swizzle_case(400, NVN_FORMAT_RGB565, 0, 1, pixels, 4, NULL, NULL, rgb);
    swizzle_case(401, NVN_FORMAT_RGB565, 0, 1, pixels, 4, rgb1, NULL, rgb);
    swizzle_case(402, NVN_FORMAT_RGB565, 0, 1, pixels, 4, rgb1, map, composed);
    swizzle_case(403, NVN_FORMAT_BGR565, 0, 1, pixels, 4, NULL, NULL, bgr);
    swizzle_case(404, NVN_FORMAT_RG8, 0, 1, pixels, 4, NULL, NULL, (float[8]){31/255.f,0,0,1, 0,248/255.f,0,1});
    uint8_t rgba[8] = {255,0,0,0, 0,0,255,64};
    swizzle_case(405, NVN_FORMAT_RGBX8, 0, 0, rgba, 8, NULL, NULL, rgb);
    swizzle_case(406, NVN_FORMAT_RGBX8, 0, 0, rgba, 8, NULL, (uint8_t[4]){NVN_SWZ_A,NVN_SWZ_A,NVN_SWZ_A,NVN_SWZ_A}, (float[8]){1,1,1,1,1,1,1,1});
    swizzle_case(407, NVN_FORMAT_RGBA8, NVN_FORMAT_RGBX8, 0, rgba, 8, NULL, NULL, rgb);
    swizzle_case(408, NVN_FORMAT_RGBA8, 0, 0, rgba, 8, NULL, NULL, (float[8]){1,0,0,0, 0,0,1,64/255.f});
    swizzle_case(409, NVN_FORMAT_RGBX8, NVN_FORMAT_RGBA8, 0, rgba, 8, NULL, NULL, (float[8]){1,0,0,0, 0,0,1,64/255.f});
    swizzle_case(410, NVN_FORMAT_RGB565, -1, 1, pixels, 4, NULL, NULL, rgb);
    swizzle_case(411, NVN_FORMAT_RGBX8, -1, 0, rgba, 8, NULL, NULL, rgb);
    swizzle_case(412, NVN_FORMAT_RGB565, 0, 0, pixels, 4, NULL, NULL, bgr);   // the same bits in a texture Metal made: Metal's order
    cleared_case(413, NVN_FORMAT_RGB565);
    cleared_case(414, NVN_FORMAT_BGR565);
    image_case(415);
    int packed[4] = {NVN_FORMAT_RGB565, NVN_FORMAT_RGB5A1, NVN_FORMAT_RGB5, NVN_FORMAT_BGR565};
    for (int i = 0; i < 4; i++) {
        init_fill_case(416 + i, packed[i], NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED);
        init_fill_case(420 + i, packed[i], NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS);
    }
    // NVN RGBA4 packs R/G/B/A from low to high: independently chosen nibbles distinguish every channel, including alpha.
    uint16_t rgba4[2] = {0x8421, 0x0f00};
    swizzle_case(424, NVN_FORMAT_RGBA4, 0, 1, rgba4, 4, NULL, NULL, (float[8]){1/15.f,2/15.f,4/15.f,8/15.f, 0,0,1,0});
    uint8_t bgra4[4] = {NVN_SWZ_B,NVN_SWZ_G,NVN_SWZ_R,NVN_SWZ_A};
    swizzle_case(425, NVN_FORMAT_RGBA4, 0, 1, rgba4, 4, bgra4, NULL, (float[8]){4/15.f,2/15.f,1/15.f,8/15.f, 1,0,0,0});
    swizzle_case(426, NVN_FORMAT_RGBA4, 0, 1, rgba4, 4, bgra4, (uint8_t[4]){NVN_SWZ_A,NVN_SWZ_B,NVN_SWZ_ONE,NVN_SWZ_ZERO}, (float[8]){8/15.f,4/15.f,1,0, 0,1,1,0});
    rgba4_linear_case(427, 0); rgba4_linear_case(428, 1);
    cleared_case(429, NVN_FORMAT_RGBA4);
    init_fill_case(430, NVN_FORMAT_RGBA4, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED);
    init_fill_case(431, NVN_FORMAT_RGBA4, NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS);
    reinterpret_case(440,0); reinterpret_case(441,1);
    reinterpret_range_case(442); reinterpret_image_case(443,0,0); reinterpret_image_case(444,1,0); reinterpret_image_case(445,0,1); reinterpret_image_case(446,0,2);
    printf("texture view swizzle: %d checks, %d failed\n", checks, fails);
    return fails != 0;
} }
