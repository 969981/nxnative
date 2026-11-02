// Feedback snapshots and their per-draw argument substitution include separate texture slots; a snapshot is reused until the game's next barrier,
// and a draw that only samples an attachment nothing in its pass has written reads it directly.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)

static id<MTLTexture> target(tex_t *t, uint64_t serial) {
    *t = (tex_t){.magic=MAGIC('T','E','X',0), .serial=serial};
    t->d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_RGBA8,
        .width=4, .height=4, .depth=1, .levels=1, .samples=1};
    MTLTextureDescriptor *d = tex_desc(t, 0); d.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [g_dev newTextureWithDescriptor:d];
    CHECK(texture != nil, "render target created");
    res_add(texture); mtl_tex_init(t); serial_put(serial, texture);
    return texture;
}
static void clear(MTLClearColor color) {
    R.clear_c[0] = 1; R.cc[0] = color;
    CHECK(rp_begin() != nil, "production render pass opens");
}
static void sample(NvShader *fs, id<MTLRenderPipelineState> pipeline) {
    clear(MTLClearColorMake(0, 0, 0, 1));
    enc_r_pso(g_enc, pipeline);
    enc_r_viewport(g_enc, (MTLViewport){0, 0, 4, 4, 0, 1});
    CHECK(encode_args((id<MTLCommandEncoder>)g_enc, fs, 1, 0), "production fragment arguments encoded");
    enc_r_draw(g_enc, MTLPrimitiveTypeTriangle, 0, 3);
    rp_end();
}
static void readback(id<MTLTexture> t, id<MTLBuffer> b, unsigned offset) {
    enc_b_copy_texture_buffer(blit(), t, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(4, 4, 1), b, offset, 256, 1024);
}
static void pixels(id<MTLBuffer> b, unsigned offset, const uint8_t want[4], const char *label) {
    int valid = 1;
    for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++)
        valid &= !memcmp((const uint8_t *)b.contents + offset + y * 256 + x * 4, want, 4);
    CHECK(valid, label);
}
static void slot_case(NvProg *pr, id<MTLRenderPipelineState> pipeline, int slot, int index) {
    int before = failed, tid = 600 + index;
    NvShader *fs = pr->sh[1]; fs->rf.b[0].reg = slot;
    tex_t source, output;
    id<MTLTexture> original = target(&source, 99700 + index * 2);
    id<MTLTexture> destination = target(&output, 99701 + index * 2);
    mtl_reg_tex(tid, &source, NULL);
    id<MTLBuffer> result = [g_dev newBufferWithLength:2048 options:MTLResourceStorageModeShared]; res_add(result);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &source; S.tex[1][slot] = tid;
    clear(MTLClearColorMake(1, 0, 0, 1));
    fb_prepare(pr);
    CHECK(!g_enc, "snapshot closes the preceding render pass");
    CHECK(g_fb_n == 1, "feedback attachment receives a snapshot");
    CHECK(g_fb_n == 1 && g_fb_src[0] == original && g_fb_use[0] != original,
          "snapshot substitutes a distinct texture for the registered source");
    rp_end();
    // Overwrite the attachment after the snapshot, then render the sampled value
    // into a distinct target. This makes a missing snapshot fail deterministically
    // even on GPUs that happen to tolerate sampling an attached render target.
    clear(MTLClearColorMake(0, 1, 0, 1)); rp_end();
    R.rt.color[0] = &output;
    sample(fs, pipeline);
    uint64_t bound = *(uint64_t *)((uint8_t *)fs->ab_buf.contents + fs->ab_off);
    CHECK(g_fb_n == 1 && bound == g_fb_rid[0] && bound != original.gpuResourceID._impl,
          "production argument buffer contains the snapshot resource ID");
    readback(destination, result, 0);
    // With a different attachment the following draw restores the original binding.
    fb_prepare(pr);
    CHECK(g_fb_n == 0, "following draw needs no snapshot");
    sample(fs, pipeline);
    bound = *(uint64_t *)((uint8_t *)fs->ab_buf.contents + fs->ab_off);
    CHECK(bound == original.gpuResourceID._impl, "following draw restores the original resource ID");
    readback(destination, result, 1024);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "GPU submission completed");
    CHECK(!mtl_last_commit_error(), "GPU submission has no error");
    pixels(result, 0, (const uint8_t[]){255, 0, 0, 255}, "first draw reads the red pre-overwrite snapshot");
    pixels(result, 1024, (const uint8_t[]){0, 255, 0, 255}, "following draw reads the green original attachment");
    printf("feedback slot %d: %s\n", slot, before == failed ? "PASS" : "FAIL");
    mtl_tex_release(&source); mtl_tex_release(&output);
}
// The rule without a listed shader: copy once, reuse until a barrier, end the pass when an earlier draw of it read the attachment directly.
static void reuse_case(NvProg *pr) {
    int before = failed, tid = 650; NvShader *fs = pr->sh[1]; fs->rf.b[0].reg = 0;
    tex_t source; target(&source, 99790);
    mtl_reg_tex(tid, &source, NULL);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &source; S.tex[1][0] = tid;
    S.chmask.mask = 0; clear(MTLClearColorMake(1, 0, 0, 1));
    uint64_t copies = g_fb_count;
    fb_prepare(pr);
    CHECK(g_fb_n == 0 && g_enc, "a draw that writes nothing reads an unwritten attachment directly");
    S.chmask.mask = 0xffffffffu;
    fb_prepare(pr);
    CHECK(g_fb_n == 1 && !g_enc && g_fb_count == copies + 1, "a writing draw takes a snapshot");
    id<MTLTexture> first = g_fb_use[0];
    clear(MTLClearColorMake(0, 1, 0, 1));
    fb_prepare(pr);
    CHECK(g_fb_n == 1 && g_enc && g_fb_count == copies + 1 && g_fb_use[0] == first, "the next writing draw reuses the snapshot without ending the pass");
    S.chmask.mask = 0; rp_end(); clear(MTLClearColorMake(0, 1, 0, 1));
    fb_prepare(pr);
    CHECK(g_fb_n == 0 && g_enc, "a reading draw first in a pass reads directly");
    S.chmask.mask = 0xffffffffu;
    fb_prepare(pr);
    CHECK(g_fb_n == 1 && !g_enc && g_fb_count == copies + 1, "a writing draw after a direct read ends the pass and reuses the snapshot");
    g_fb_bar++;
    clear(MTLClearColorMake(0, 0, 1, 1));
    fb_prepare(pr);
    CHECK(g_fb_n == 1 && !g_enc && g_fb_count == copies + 2, "a game barrier makes the next writing draw take a fresh snapshot");
    rp_end();
    // The depth attachment read, then written in the same pass (only serials matter to the rule: the attachment is named after the pass opens)
    { tex_t output, depth; target(&output, 99791); target(&depth, 99792); mtl_reg_tex(651, &depth, NULL);   // NOLINT(clang-analyzer-osx.cocoa.RetainCount): g_by_serial owns both textures (serial_put's CFBridgingRetain) until mtl_tex_release below, not a leak
      R.rt.color[0] = &output; R.rt.depth = NULL; S.tex[1][0] = 651; S.chmask.mask = 0xffffffffu; S.ds.dt = 1; S.ds.dw = 0;
      clear(MTLClearColorMake(0, 0, 0, 1)); R.rt.depth = &depth;
      fb_prepare(pr);
      CHECK(g_enc != nil, "a draw that reads the depth attachment stays in its pass");
      fb_prepare(pr);
      CHECK(g_enc != nil, "so does the next one, which writes no depth");
      S.ds.dw = 1; fb_prepare(pr);
      CHECK(!g_enc, "a draw writing depth after a read of it ends the pass");
      R.rt.depth = NULL; clear(MTLClearColorMake(0, 0, 0, 1)); rp_end();   // that draw read it too, and began the pass it would open: the next pass is a clean one
      clear(MTLClearColorMake(0, 0, 0, 1)); R.rt.depth = &depth; S.tex[1][0] = 0;
      fb_prepare(pr);
      CHECK(g_enc != nil, "a draw writing depth with no read of it in its pass stays");
      R.rt.depth = NULL; S.ds.dt = S.ds.dw = 0; rp_end(); mtl_tex_release(&output); mtl_tex_release(&depth); }
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "GPU submission completed");
    CHECK(!mtl_last_commit_error(), "GPU submission has no error");
    printf("feedback reuse: %s\n", before == failed ? "PASS" : "FAIL");
    mtl_tex_release(&source);
}
// A feedback view must retain its mip numbers in both directions, including a
// nonzero-base view. Poisoning the original chain makes a missing copy fail
// deterministically rather than depending on undefined attachment reads.
static void mip_case(id<MTLLibrary> lib, int attached, int first, int sampled, int index, int shape) {
    int before = failed, tid = 780 + index, layers = shape == 2 ? 6 : shape == 1 ? 3 : 1, layer = shape == 2 ? 4 : shape == 1 ? 2 : 0;
    tex_t source = {.magic=MAGIC('T','E','X',0), .serial=99900 + index}, output;
    source.d = (nvn_texdesc){.target=shape == 2 ? NVN_TEXTURE_TARGET_CUBEMAP : shape == 1 ? NVN_TEXTURE_TARGET_2D_ARRAY : NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_RGBA8,
        .width=16, .height=16, .depth=layers, .levels=4, .samples=1};
    MTLTextureDescriptor *td = tex_desc(&source, 0); td.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [g_dev newTextureWithDescriptor:td];
    CHECK(texture != nil, "mip feedback fixture allocated"); if (!texture) return;
    res_add(texture); mtl_tex_init(&source); serial_put(source.serial, texture);
    const uint8_t colors[4][4] = {{255,0,0,255}, {0,255,0,255}, {0,0,255,255}, {255,255,0,255}};
    for (int m = 0; m < 4; m++) {
        uint8_t data[16 * 16 * 4]; int width = 16 >> m;
        for (int s = 0; s < layers; s++) {
            for (int p = 0; p < width * width; p++) memcpy(data + p * 4, s == layer ? colors[m] : (const uint8_t[]){0,0,0,255}, 4);
            [texture replaceRegion:MTLRegionMake2D(0, 0, width, width) mipmapLevel:m slice:s withBytes:data bytesPerRow:width * 4 bytesPerImage:width * width * 4];
        }
    }
    view_t view = {.set_levels=1, .base_level=first, .nlevels=4-first};
    if (shape == 1) { view.set_layers = 1; view.min_layer = 1; view.nlayers = 2; }
    mtl_reg_tex(tid, &source, &view);
    id<MTLTexture> destination = target(&output, 99910 + index);
    id<MTLBuffer> result = [g_dev newBufferWithLength:1024 options:MTLResourceStorageModeShared]; res_add(result);
    NvProg *pr = [NvProg new]; NvShader *fs = [NvShader new]; pr->sh[1] = fs;
    fs->stage = 1; strcpy(fs->key, "aabbccddeeff0011");
    fs->fn = [lib newFunctionWithName:shape == 2 ? @"fmc2" : shape == 1 ? @"fma2" : sampled == 1 ? @"fm1" : @"fm2"];
    fs->ae = [fs->fn newArgumentEncoderWithBufferIndex:0]; fs->arg_len = fs->ae.encodedLength;
    fs->rf.nb = 1; fs->rf.b[0] = (nvn_rbind){.kind=NVN_RB_TEX, .aid=0, .dtt=shape == 2 ? MTLTextureTypeCube : shape == 1 ? MTLTextureType2DArray : MTLTextureType2D};
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"v"]; pd.fragmentFunction = fs->fn;
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    NSError *error = nil; id<MTLRenderPipelineState> pipeline = [g_dev newRenderPipelineStateWithDescriptor:pd error:&error];
    CHECK(pipeline != nil, "mip feedback consumer compiled"); if (!pipeline) return;
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &source; S.tex[1][0] = tid;
    R.rt.has_cview[0] = 1; R.rt.cview[0] = (view_t){.set_levels=1, .base_level=attached, .nlevels=1, .set_layers=1, .min_layer=layer, .nlayers=1};
    clear(MTLClearColorMake(colors[attached][0] / 255., colors[attached][1] / 255., colors[attached][2] / 255., 1));
    uint64_t copies = g_fb_count;
    fb_prepare(pr); rp_end();
    // Same serial and base level/layer, but a different mip count: neither shape
    // may reuse the other's valid contents within this barrier and submission.
    view_t prefix = view; prefix.nlevels = attached - first + 1;
    mtl_reg_tex(tid, &source, &prefix); fb_prepare(pr); rp_end();
    mtl_reg_tex(tid, &source, &view); fb_prepare(pr); rp_end();
    CHECK(g_fb_n == 1 && g_fb_use[0].mipmapLevelCount == (NSUInteger)(4 - first) && g_fb_count == copies + 3,
          "same-key range changes refresh the snapshot and restore the full sampled shape");
    for (int m = 0; m < 4; m++) for (int s = 0; s < layers; s++) {
        R.rt.cview[0].base_level = m; R.rt.cview[0].min_layer = s;
        clear(MTLClearColorMake(1, 0, 1, 1)); rp_end();
    }
    R.rt.color[0] = &output; R.rt.has_cview[0] = 0;
    sample(fs, pipeline); readback(destination, result, 0);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "mip feedback GPU submission completed");
    CHECK(!mtl_last_commit_error(), "mip feedback GPU submission has no error");
    pixels(result, 0, colors[first + sampled], "feedback preserves the requested mip's pre-overwrite pixels");
    printf("feedback mip shape=%d attachment=%d view-base=%d sampled=%d: %s\n", shape, attached, first, sampled, before == failed ? "PASS" : "FAIL");
    mtl_tex_release(&source); mtl_tex_release(&output);
}

int main(void) { @autoreleasepool {
    setenv("DM_NVN_TBDR", "0", 1);
    mtl_init(); NSError *error = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i[[vertex_id]]) { return float4(i == 1 ? 3.0 : -1.0, i == 2 ? 3.0 : -1.0, 0, 1); }\n"
        "struct A {texture2d<float, access::read> source[[id(0)]];};\n"
        "fragment float4 f(float4 p[[position]], constant A&a[[buffer(0)]]) {return a.source.read(uint2(p.xy));}\n"
        "struct AM {texture2d<float> source[[id(0)]];};\n"
        "fragment float4 fm1(constant AM&a[[buffer(0)]]) {constexpr sampler s(coord::normalized,filter::linear,mip_filter::linear); return a.source.sample(s,float2(.5),level(1));}\n"
        "fragment float4 fm2(constant AM&a[[buffer(0)]]) {constexpr sampler s(coord::normalized,filter::linear,mip_filter::linear); return a.source.sample(s,float2(.5),level(2));}\n"
        "struct AMA {texture2d_array<float> source[[id(0)]];};\n"
        "fragment float4 fma2(constant AMA&a[[buffer(0)]]) {constexpr sampler s(coord::normalized,filter::linear,mip_filter::linear); return a.source.sample(s,float2(.5),1,level(2));}\n"
        "struct AMC {texturecube<float> source[[id(0)]];};\n"
        "fragment float4 fmc2(constant AMC&a[[buffer(0)]]) {constexpr sampler s(coord::normalized,filter::linear,mip_filter::linear); return a.source.sample(s,float3(0,0,1),level(2));}\n"
        options:nil error:&error];
    CHECK(lib != nil, "synthetic shader compiles");
    if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    NvProg *pr = [NvProg new]; NvShader *fs = [NvShader new]; pr->sh[1] = fs;
    fs->stage = 1; strcpy(fs->key, "0123456789abcdef"); fs->fn = [lib newFunctionWithName:@"f"];
    fs->ae = [fs->fn newArgumentEncoderWithBufferIndex:0]; fs->arg_len = fs->ae.encodedLength;
    fs->rf.nb = 1; fs->rf.b[0] = (nvn_rbind){.kind=NVN_RB_TEX, .aid=0, .dtt=MTLTextureType2D};
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"v"]; d.fragmentFunction = fs->fn;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> pipeline = [g_dev newRenderPipelineStateWithDescriptor:d error:&error];
    CHECK(pipeline != nil, "synthetic render pipeline compiles");
    if (!pipeline) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    const int slots[] = {0, 128, 255};
    for (int i = 0; i < 3; i++) slot_case(pr, pipeline, slots[i], i);
    reuse_case(pr);
    mip_case(lib, 2, 0, 1, 0, 0);
    mip_case(lib, 1, 0, 2, 1, 0);
    mip_case(lib, 2, 1, 2, 2, 0);
    mip_case(lib, 1, 0, 2, 3, 1);
    mip_case(lib, 1, 0, 2, 4, 2);
    printf("feedback snapshot: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
