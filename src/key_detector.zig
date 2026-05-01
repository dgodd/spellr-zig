/// Naive Bayes classifier for detecting API keys / base64 strings.
/// Weights are baked in from lib/spellr/key_tuner/data.yml.
const std = @import("std");

const NUM_FEATURES = 37;
const NUM_CLASSES = 8;

const FeatureStats = struct { mean: f64, variance: f64 };

const ClassWeights = struct {
    @"+": FeatureStats,
    @"-": FeatureStats,
    @"_": FeatureStats,
    @"/": FeatureStats,
    A: FeatureStats,
    z: FeatureStats,
    Z: FeatureStats,
    q: FeatureStats,
    Q: FeatureStats,
    X: FeatureStats,
    x: FeatureStats,
    equal: FeatureStats,
    length: FeatureStats,
    hex: FeatureStats,
    lower36: FeatureStats,
    upper36: FeatureStats,
    base64: FeatureStats,
    mean_title_chunk_size: FeatureStats,
    variance_title_chunk_size: FeatureStats,
    max_title_chunk_size: FeatureStats,
    mean_lower_chunk_size: FeatureStats,
    variance_lower_chunk_size: FeatureStats,
    mean_upper_chunk_size: FeatureStats,
    variance_upper_chunk_size: FeatureStats,
    mean_alpha_chunk_size: FeatureStats,
    variance_alpha_chunk_size: FeatureStats,
    mean_alnum_chunk_size: FeatureStats,
    variance_alnum_chunk_size: FeatureStats,
    mean_digit_chunk_size: FeatureStats,
    variance_digit_chunk_size: FeatureStats,
    vowel_consonant_ratio: FeatureStats,
    alpha_chunks: FeatureStats,
    alnum_chunks: FeatureStats,
    digit_chunks: FeatureStats,
    title_chunks: FeatureStats,
    mean_letter_frequency_difference: FeatureStats,
    variance_letter_frequency_difference: FeatureStats,
};

// Classes ordered: 0=not_key_lower36, 1=not_key_base64, 2=not_key_hex,
//                  3=not_key_upper36, 4=key_base64, 5=key_hex, 6=key_lower36, 7=key_upper36
const CLASS_NAMES = [NUM_CLASSES][]const u8{
    "not_key_lower36", "not_key_base64", "not_key_hex", "not_key_upper36",
    "key_base64",      "key_hex",        "key_lower36", "key_upper36",
};

// Returns true if class index is a "key" class
fn isKeyClass(idx: usize) bool { return idx >= 4; }

const WEIGHTS = [NUM_CLASSES]ClassWeights{
    // 0: not_key_lower36
    .{
        .@"+" = .{ .mean = 0.31397306397306396, .variance = 0.022188778922785653 },
        .@"-" = .{ .mean = 0.31397306397306396, .variance = 0.022188778922785653 },
        .@"_" = .{ .mean = 0.31397306397306396, .variance = 0.022188778922785653 },
        .@"/" = .{ .mean = 0.31397306397306396, .variance = 0.022188778922785653 },
        .A = .{ .mean = 0.31397306397306396, .variance = 0.022188778922785653 },
        .z = .{ .mean = 0.31397306397306396, .variance = 0.022188778922785653 },
        .Z = .{ .mean = 0.31397306397306396, .variance = 0.022188778922785653 },
        .q = .{ .mean = 0.30690235690235684, .variance = 0.02418823476062533 },
        .Q = .{ .mean = 0.31397306397306396, .variance = 0.022188778922785653 },
        .X = .{ .mean = 0.31397306397306396, .variance = 0.022188778922785653 },
        .x = .{ .mean = 0.30690235690235684, .variance = 0.02418823476062533 },
        .equal = .{ .mean = 0.0, .variance = 0.0 },
        .length = .{ .mean = 11.303030303030303, .variance = 28.756657483930212 },
        .hex = .{ .mean = 0.0, .variance = 0.0 },
        .lower36 = .{ .mean = 1.0, .variance = 0.0 },
        .upper36 = .{ .mean = 0.0, .variance = 0.0 },
        .base64 = .{ .mean = 0.0, .variance = 0.0 },
        .mean_title_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .variance_title_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .max_title_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .mean_lower_chunk_size = .{ .mean = 4.457070707070708, .variance = 4.84011835526987 },
        .variance_lower_chunk_size = .{ .mean = 8.281776094276093, .variance = 238.59616719949207 },
        .mean_upper_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .variance_upper_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .mean_alpha_chunk_size = .{ .mean = 4.457070707070708, .variance = 4.84011835526987 },
        .variance_alpha_chunk_size = .{ .mean = 8.281776094276093, .variance = 238.59616719949207 },
        .mean_alnum_chunk_size = .{ .mean = 11.303030303030303, .variance = 28.756657483930212 },
        .variance_alnum_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .mean_digit_chunk_size = .{ .mean = 1.2676767676767677, .variance = 0.28777675747372716 },
        .variance_digit_chunk_size = .{ .mean = 0.029461279461279462, .variance = 0.006310297135212959 },
        .vowel_consonant_ratio = .{ .mean = 0.09090909090909091, .variance = 0.08264462809917354 },
        .alpha_chunks = .{ .mean = 2.1515151515151514, .variance = 0.1891643709825528 },
        .alnum_chunks = .{ .mean = 1.0, .variance = 0.0 },
        .digit_chunks = .{ .mean = 1.2727272727272727, .variance = 0.25895316804407714 },
        .title_chunks = .{ .mean = 0.0, .variance = 0.0 },
        .mean_letter_frequency_difference = .{ .mean = 0.299351367261815, .variance = 0.022114928817018507 },
        .variance_letter_frequency_difference = .{ .mean = 0.31397306397306396, .variance = 0.022188778922785653 },
    },
    // 1: not_key_base64
    .{
        .@"+" = .{ .mean = 0.3888229606188467, .variance = 0.06458699929905236 },
        .@"-" = .{ .mean = 0.37484730018783585, .variance = 0.06441346177080855 },
        .@"_" = .{ .mean = 0.34891859428821026, .variance = 0.061840198871359525 },
        .@"/" = .{ .mean = 0.36237670731007626, .variance = 0.057997138047872224 },
        .A = .{ .mean = 0.37797187602172644, .variance = 0.06658320833305277 },
        .z = .{ .mean = 0.3890360503174757, .variance = 0.06410930763241254 },
        .Z = .{ .mean = 0.38970200421940926, .variance = 0.06407112526760757 },
        .q = .{ .mean = 0.38725722619368014, .variance = 0.06453715420414655 },
        .Q = .{ .mean = 0.38710301560100957, .variance = 0.06473933727360218 },
        .X = .{ .mean = 0.38961027793065495, .variance = 0.06401274620070103 },
        .x = .{ .mean = 0.3852291846408556, .variance = 0.06544875358948515 },
        .equal = .{ .mean = 0.02531645569620253, .variance = 0.024675532767184743 },
        .length = .{ .mean = 24.940928270042193, .variance = 262.4353290961206 },
        .hex = .{ .mean = 0.0, .variance = 0.0 },
        .lower36 = .{ .mean = 0.0, .variance = 0.0 },
        .upper36 = .{ .mean = 0.0, .variance = 0.0 },
        .base64 = .{ .mean = 1.0, .variance = 0.0 },
        .mean_title_chunk_size = .{ .mean = 2.3335794655414905, .variance = 6.595865211336424 },
        .variance_title_chunk_size = .{ .mean = 0.6990329264617239, .variance = 3.144165985036278 },
        .max_title_chunk_size = .{ .mean = 2.9071729957805905, .variance = 10.852142640958535 },
        .mean_lower_chunk_size = .{ .mean = 3.858481819399541, .variance = 3.6694284749138255 },
        .variance_lower_chunk_size = .{ .mean = 3.7600050590117027, .variance = 25.143933623597718 },
        .mean_upper_chunk_size = .{ .mean = 0.9685654008438819, .variance = 1.467644074133419 },
        .variance_upper_chunk_size = .{ .mean = 0.5595675105485233, .variance = 20.803517521774562 },
        .mean_alpha_chunk_size = .{ .mean = 5.781797404423986, .variance = 9.075136326046163 },
        .variance_alpha_chunk_size = .{ .mean = 11.714747648069515, .variance = 573.3379179386894 },
        .mean_alnum_chunk_size = .{ .mean = 8.991178261356966, .variance = 49.22747308052533 },
        .variance_alnum_chunk_size = .{ .mean = 8.18210737474977, .variance = 269.2877221673833 },
        .mean_digit_chunk_size = .{ .mean = 1.7030942334739803, .variance = 2.0947489817435874 },
        .variance_digit_chunk_size = .{ .mean = 0.9975480543834974, .variance = 9.605482225708176 },
        .vowel_consonant_ratio = .{ .mean = 0.1350210970464135, .variance = 0.15054567466039984 },
        .alpha_chunks = .{ .mean = 3.586497890295359, .variance = 5.339564528476561 },
        .alnum_chunks = .{ .mean = 3.5738396624472575, .variance = 8.59053926543111 },
        .digit_chunks = .{ .mean = 1.358649789029536, .variance = 0.8122985988712635 },
        .title_chunks = .{ .mean = 1.4303797468354431, .variance = 3.5362922608556318 },
        .mean_letter_frequency_difference = .{ .mean = 0.3754562361065053, .variance = 0.063718939042522 },
        .variance_letter_frequency_difference = .{ .mean = 0.3902671036769138, .variance = 0.06379182213572351 },
    },
    // 2: not_key_hex
    .{
        .@"+" = .{ .mean = 0.5208333333333334, .variance = 0.016493055555555556 },
        .@"-" = .{ .mean = 0.4602272727272727, .variance = 0.0036372245179063342 },
        .@"_" = .{ .mean = 0.5208333333333334, .variance = 0.016493055555555556 },
        .@"/" = .{ .mean = 0.5208333333333334, .variance = 0.016493055555555556 },
        .A = .{ .mean = 0.5208333333333334, .variance = 0.016493055555555556 },
        .z = .{ .mean = 0.5208333333333334, .variance = 0.016493055555555556 },
        .Z = .{ .mean = 0.5208333333333334, .variance = 0.016493055555555556 },
        .q = .{ .mean = 0.5208333333333334, .variance = 0.016493055555555556 },
        .Q = .{ .mean = 0.5208333333333334, .variance = 0.016493055555555556 },
        .X = .{ .mean = 0.5208333333333334, .variance = 0.016493055555555556 },
        .x = .{ .mean = 0.5208333333333334, .variance = 0.016493055555555556 },
        .equal = .{ .mean = 0.0, .variance = 0.0 },
        .length = .{ .mean = 8.333333333333334, .variance = 4.222222222222222 },
        .hex = .{ .mean = 1.0, .variance = 0.0 },
        .lower36 = .{ .mean = 0.0, .variance = 0.0 },
        .upper36 = .{ .mean = 0.0, .variance = 0.0 },
        .base64 = .{ .mean = 0.0, .variance = 0.0 },
        .mean_title_chunk_size = .{ .mean = 1.0, .variance = 2.0 },
        .variance_title_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .max_title_chunk_size = .{ .mean = 1.0, .variance = 2.0 },
        .mean_lower_chunk_size = .{ .mean = 5.333333333333333, .variance = 6.222222222222222 },
        .variance_lower_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .mean_upper_chunk_size = .{ .mean = 0.3333333333333333, .variance = 0.22222222222222224 },
        .variance_upper_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .mean_alpha_chunk_size = .{ .mean = 5.666666666666667, .variance = 4.222222222222222 },
        .variance_alpha_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .mean_alnum_chunk_size = .{ .mean = 5.666666666666667, .variance = 4.222222222222222 },
        .variance_alnum_chunk_size = .{ .mean = 0.2222222222222222, .variance = 0.09876543209876543 },
        .mean_digit_chunk_size = .{ .mean = 1.0, .variance = 2.0 },
        .variance_digit_chunk_size = .{ .mean = 0.3333333333333333, .variance = 0.22222222222222224 },
        .vowel_consonant_ratio = .{ .mean = 0.6666666666666666, .variance = 0.22222222222222224 },
        .alpha_chunks = .{ .mean = 1.0, .variance = 0.0 },
        .alnum_chunks = .{ .mean = 1.6666666666666667, .variance = 0.888888888888889 },
        .digit_chunks = .{ .mean = 0.6666666666666666, .variance = 0.888888888888889 },
        .title_chunks = .{ .mean = 0.3333333333333333, .variance = 0.22222222222222224 },
        .mean_letter_frequency_difference = .{ .mean = 0.505907960199005, .variance = 0.01649305555555555 },
        .variance_letter_frequency_difference = .{ .mean = 0.5208333333333334, .variance = 0.016493055555555556 },
    },
    // 3: not_key_upper36
    .{
        .@"+" = .{ .mean = 0.2904040404040404, .variance = 0.009450566268748087 },
        .@"-" = .{ .mean = 0.2904040404040404, .variance = 0.009450566268748087 },
        .@"_" = .{ .mean = 0.2904040404040404, .variance = 0.009450566268748087 },
        .@"/" = .{ .mean = 0.2904040404040404, .variance = 0.009450566268748087 },
        .A = .{ .mean = 0.19174007810371443, .variance = 0.009236689398211761 },
        .z = .{ .mean = 0.2904040404040404, .variance = 0.009450566268748087 },
        .Z = .{ .mean = 0.2904040404040404, .variance = 0.009450566268748087 },
        .q = .{ .mean = 0.2904040404040404, .variance = 0.009450566268748087 },
        .Q = .{ .mean = 0.2904040404040404, .variance = 0.009450566268748087 },
        .X = .{ .mean = 0.26605339105339104, .variance = 0.016175398074748725 },
        .x = .{ .mean = 0.2904040404040404, .variance = 0.009450566268748087 },
        .equal = .{ .mean = 0.0, .variance = 0.0 },
        .length = .{ .mean = 10.454545454545455, .variance = 12.24793388429752 },
        .hex = .{ .mean = 0.0, .variance = 0.0 },
        .lower36 = .{ .mean = 0.0, .variance = 0.0 },
        .upper36 = .{ .mean = 1.0, .variance = 0.0 },
        .base64 = .{ .mean = 0.0, .variance = 0.0 },
        .mean_title_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .variance_title_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .max_title_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .mean_lower_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .variance_lower_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .mean_upper_chunk_size = .{ .mean = 4.681818181818182, .variance = 3.285123966942149 },
        .variance_upper_chunk_size = .{ .mean = 3.3863636363636362, .variance = 21.015495867768593 },
        .mean_alpha_chunk_size = .{ .mean = 4.681818181818182, .variance = 3.285123966942149 },
        .variance_alpha_chunk_size = .{ .mean = 3.3863636363636362, .variance = 21.015495867768593 },
        .mean_alnum_chunk_size = .{ .mean = 10.454545454545455, .variance = 12.24793388429752 },
        .variance_alnum_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .mean_digit_chunk_size = .{ .mean = 1.0909090909090908, .variance = 0.08264462809917356 },
        .variance_digit_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .vowel_consonant_ratio = .{ .mean = 0.2727272727272727, .variance = 0.1983471074380165 },
        .alpha_chunks = .{ .mean = 2.0, .variance = 0.0 },
        .alnum_chunks = .{ .mean = 1.0, .variance = 0.0 },
        .digit_chunks = .{ .mean = 1.0, .variance = 0.0 },
        .title_chunks = .{ .mean = 0.0, .variance = 0.0 },
        .mean_letter_frequency_difference = .{ .mean = 0.27580172729426455, .variance = 0.009393385597628003 },
        .variance_letter_frequency_difference = .{ .mean = 0.2904040404040404, .variance = 0.009450566268748087 },
    },
    // 4: key_base64
    .{
        .@"+" = .{ .mean = 0.7620479677679989, .variance = 0.22932788593099632 },
        .@"-" = .{ .mean = 0.7674698211603613, .variance = 0.23541768114473247 },
        .@"_" = .{ .mean = 0.7683147592547762, .variance = 0.2348675719024521 },
        .@"/" = .{ .mean = 0.7593109857187765, .variance = 0.2301098843967043 },
        .A = .{ .mean = 0.7159949406166164, .variance = 0.22348770070203433 },
        .z = .{ .mean = 0.7593094160660077, .variance = 0.2326241476630803 },
        .Z = .{ .mean = 0.7550733796707711, .variance = 0.22904557152964244 },
        .q = .{ .mean = 0.758355010937151, .variance = 0.23020553470836227 },
        .Q = .{ .mean = 0.7559053227669673, .variance = 0.22903026100159712 },
        .X = .{ .mean = 0.7576780710354446, .variance = 0.23183503927782617 },
        .x = .{ .mean = 0.7574254814910006, .variance = 0.23100902376886814 },
        .equal = .{ .mean = 0.07052561543579508, .variance = 0.09881855273706303 },
        .length = .{ .mean = 49.26480372588157, .variance = 956.2998057997999 },
        .hex = .{ .mean = 0.0, .variance = 0.0 },
        .lower36 = .{ .mean = 0.0, .variance = 0.0 },
        .upper36 = .{ .mean = 0.0, .variance = 0.0 },
        .base64 = .{ .mean = 1.0, .variance = 0.0 },
        .mean_title_chunk_size = .{ .mean = 2.2847907490166315, .variance = 0.881109102517196 },
        .variance_title_chunk_size = .{ .mean = 0.5945675969444422, .variance = 0.7054902041084655 },
        .max_title_chunk_size = .{ .mean = 3.5276114437791084, .variance = 3.6797099967286537 },
        .mean_lower_chunk_size = .{ .mean = 1.5511671225738333, .variance = 0.3453900944079824 },
        .variance_lower_chunk_size = .{ .mean = 0.7229509172836843, .variance = 0.8423486483166585 },
        .mean_upper_chunk_size = .{ .mean = 2.462205221040871, .variance = 13.666972653798798 },
        .variance_upper_chunk_size = .{ .mean = 14.962714945400833, .variance = 6274.596714711332 },
        .mean_alpha_chunk_size = .{ .mean = 6.076705282839681, .variance = 27.897261980233036 },
        .variance_alpha_chunk_size = .{ .mean = 40.43368299794101, .variance = 11951.164762236152 },
        .mean_alnum_chunk_size = .{ .mean = 26.629095704694507, .variance = 512.6868988291579 },
        .variance_alnum_chunk_size = .{ .mean = 121.93367215571097, .variance = 51947.139075131694 },
        .mean_digit_chunk_size = .{ .mean = 1.2085493841610866, .variance = 0.20795215029431086 },
        .variance_digit_chunk_size = .{ .mean = 0.24678149607358768, .variance = 4.131434963876628 },
        .vowel_consonant_ratio = .{ .mean = 0.35595475715236197, .variance = 2.267840455704249 },
        .alpha_chunks = .{ .mean = 7.324683965402528, .variance = 23.097507800987067 },
        .alnum_chunks = .{ .mean = 2.2035928143712575, .variance = 2.6930809040601433 },
        .digit_chunks = .{ .mean = 5.8496340652029275, .variance = 18.314050098959324 },
        .title_chunks = .{ .mean = 7.501663339986694, .variance = 36.94061599577514 },
        .mean_letter_frequency_difference = .{ .mean = 0.757096597371617, .variance = 0.2305160694470263 },
        .variance_letter_frequency_difference = .{ .mean = 0.7824197834489751, .variance = 0.2178339931463347 },
    },
    // 5: key_hex
    .{
        .@"+" = .{ .mean = 1.914128895184136, .variance = 2.6500270032160596 },
        .@"-" = .{ .mean = 1.8968935536160076, .variance = 2.6402537652467646 },
        .@"_" = .{ .mean = 1.914128895184136, .variance = 2.6500270032160596 },
        .@"/" = .{ .mean = 1.914128895184136, .variance = 2.6500270032160596 },
        .A = .{ .mean = 1.8633401715870046, .variance = 2.803124455039616 },
        .z = .{ .mean = 1.914128895184136, .variance = 2.6500270032160596 },
        .Z = .{ .mean = 1.914128895184136, .variance = 2.6500270032160596 },
        .q = .{ .mean = 1.914128895184136, .variance = 2.6500270032160596 },
        .Q = .{ .mean = 1.914128895184136, .variance = 2.6500270032160596 },
        .X = .{ .mean = 1.914128895184136, .variance = 2.6500270032160596 },
        .x = .{ .mean = 1.914128895184136, .variance = 2.6500270032160596 },
        .equal = .{ .mean = 0.0, .variance = 0.0 },
        .length = .{ .mean = 30.626062322946176, .variance = 678.4069128233112 },
        .hex = .{ .mean = 1.0, .variance = 0.0 },
        .lower36 = .{ .mean = 0.0, .variance = 0.0 },
        .upper36 = .{ .mean = 0.0, .variance = 0.0 },
        .base64 = .{ .mean = 0.0, .variance = 0.0 },
        .mean_title_chunk_size = .{ .mean = 0.046742209631728045, .variance = 0.09554887688690222 },
        .variance_title_chunk_size = .{ .mean = 0.002124645892351275, .variance = 0.0031824547183590276 },
        .max_title_chunk_size = .{ .mean = 0.049575070821529746, .variance = 0.11793891291961255 },
        .mean_lower_chunk_size = .{ .mean = 1.3985280204157986, .variance = 0.6546173578612767 },
        .variance_lower_chunk_size = .{ .mean = 0.7691019261778345, .variance = 1.0236126914212886 },
        .mean_upper_chunk_size = .{ .mean = 0.4866096721974909, .variance = 0.8593048098231186 },
        .variance_upper_chunk_size = .{ .mean = 0.2590497712173737, .variance = 0.3887672997527058 },
        .mean_alpha_chunk_size = .{ .mean = 1.8681337805668847, .variance = 0.2722697810226553 },
        .variance_alpha_chunk_size = .{ .mean = 1.0639635915579726, .variance = 1.235755775785176 },
        .mean_alnum_chunk_size = .{ .mean = 26.07167138810198, .variance = 743.6308405492381 },
        .variance_alnum_chunk_size = .{ .mean = 1.551274787535411, .variance = 13.471964663868583 },
        .mean_digit_chunk_size = .{ .mean = 2.154084975711082, .variance = 0.9547443666322324 },
        .variance_digit_chunk_size = .{ .mean = 2.1969818194376587, .variance = 9.079021232319018 },
        .vowel_consonant_ratio = .{ .mean = 0.4164305949008499, .variance = 2.7699283358344897 },
        .alpha_chunks = .{ .mean = 7.286118980169972, .variance = 41.24958068839329 },
        .alnum_chunks = .{ .mean = 1.613314447592068, .variance = 2.0671881645788024 },
        .digit_chunks = .{ .mean = 7.53257790368272, .variance = 44.25460440257124 },
        .title_chunks = .{ .mean = 0.026912181303116147, .variance = 0.04318508293943455 },
        .mean_letter_frequency_difference = .{ .mean = 1.899406120953307, .variance = 2.6494045660777443 },
        .variance_letter_frequency_difference = .{ .mean = 1.9142469310670442, .variance = 2.6496734807310602 },
    },
    // 6: key_lower36
    .{
        .@"+" = .{ .mean = 0.3542240587695133, .variance = 0.08435722109651485 },
        .@"-" = .{ .mean = 0.3542240587695133, .variance = 0.08435722109651485 },
        .@"_" = .{ .mean = 0.3542240587695133, .variance = 0.08435722109651485 },
        .@"/" = .{ .mean = 0.3542240587695133, .variance = 0.08435722109651485 },
        .A = .{ .mean = 0.3542240587695133, .variance = 0.08435722109651485 },
        .z = .{ .mean = 0.34137681564107686, .variance = 0.08558842611995869 },
        .Z = .{ .mean = 0.3542240587695133, .variance = 0.08435722109651485 },
        .q = .{ .mean = 0.34066932753689455, .variance = 0.08688552718341898 },
        .Q = .{ .mean = 0.3542240587695133, .variance = 0.08435722109651485 },
        .X = .{ .mean = 0.3542240587695133, .variance = 0.08435722109651485 },
        .x = .{ .mean = 0.34204109423634216, .variance = 0.08722009136654703 },
        .equal = .{ .mean = 0.0, .variance = 0.0 },
        .length = .{ .mean = 12.75206611570248, .variance = 109.32695854108327 },
        .hex = .{ .mean = 0.0, .variance = 0.0 },
        .lower36 = .{ .mean = 1.0, .variance = 0.0 },
        .upper36 = .{ .mean = 0.0, .variance = 0.0 },
        .base64 = .{ .mean = 0.0, .variance = 0.0 },
        .mean_title_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .variance_title_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .max_title_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .mean_lower_chunk_size = .{ .mean = 2.4263180804503115, .variance = 3.7308294304217022 },
        .variance_lower_chunk_size = .{ .mean = 1.4484248591583748, .variance = 29.757907567673985 },
        .mean_upper_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .variance_upper_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .mean_alpha_chunk_size = .{ .mean = 2.4263180804503115, .variance = 3.7308294304217022 },
        .variance_alpha_chunk_size = .{ .mean = 1.4484248591583748, .variance = 29.757907567673985 },
        .mean_alnum_chunk_size = .{ .mean = 12.75206611570248, .variance = 109.32695854108327 },
        .variance_alnum_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .mean_digit_chunk_size = .{ .mean = 2.1150274885812075, .variance = 0.6058596697679969 },
        .variance_digit_chunk_size = .{ .mean = 0.518260085776096, .variance = 1.680449874021543 },
        .vowel_consonant_ratio = .{ .mean = 0.024793388429752067, .variance = 0.0241786763199235 },
        .alpha_chunks = .{ .mean = 3.0082644628099175, .variance = 7.148692029232976 },
        .alnum_chunks = .{ .mean = 1.0, .variance = 0.0 },
        .digit_chunks = .{ .mean = 2.9173553719008263, .variance = 7.08407895635544 },
        .title_chunks = .{ .mean = 0.0, .variance = 0.0 },
        .mean_letter_frequency_difference = .{ .mean = 0.3397978356224316, .variance = 0.08421756005135934 },
        .variance_letter_frequency_difference = .{ .mean = 0.3557326511871966, .variance = 0.08414823859709553 },
    },
    // 7: key_upper36
    .{
        .@"+" = .{ .mean = 0.17724196277495768, .variance = 0.01398464114694027 },
        .@"-" = .{ .mean = 0.17724196277495768, .variance = 0.01398464114694027 },
        .@"_" = .{ .mean = 0.17724196277495768, .variance = 0.01398464114694027 },
        .@"/" = .{ .mean = 0.17724196277495768, .variance = 0.01398464114694027 },
        .A = .{ .mean = 0.13370667489139618, .variance = 0.01751245983259839 },
        .z = .{ .mean = 0.17724196277495768, .variance = 0.01398464114694027 },
        .Z = .{ .mean = 0.17443672633360047, .variance = 0.014294285951814888 },
        .q = .{ .mean = 0.17724196277495768, .variance = 0.01398464114694027 },
        .Q = .{ .mean = 0.1561229591051926, .variance = 0.017340496646042505 },
        .X = .{ .mean = 0.17199698696826668, .variance = 0.014672379011009729 },
        .x = .{ .mean = 0.17724196277495768, .variance = 0.01398464114694027 },
        .equal = .{ .mean = 0.0, .variance = 0.0 },
        .length = .{ .mean = 6.380710659898477, .variance = 18.124094926434587 },
        .hex = .{ .mean = 0.0, .variance = 0.0 },
        .lower36 = .{ .mean = 0.0, .variance = 0.0 },
        .upper36 = .{ .mean = 1.0, .variance = 0.0 },
        .base64 = .{ .mean = 0.0, .variance = 0.0 },
        .mean_title_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .variance_title_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .max_title_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .mean_lower_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .variance_lower_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .mean_upper_chunk_size = .{ .mean = 2.5596446700507616, .variance = 1.9222039346543327 },
        .variance_upper_chunk_size = .{ .mean = 5.446065989847716, .variance = 5115.813486356614 },
        .mean_alpha_chunk_size = .{ .mean = 2.5596446700507616, .variance = 1.9222039346543327 },
        .variance_alpha_chunk_size = .{ .mean = 5.446065989847716, .variance = 5115.813486356614 },
        .mean_alnum_chunk_size = .{ .mean = 6.380710659898477, .variance = 18.124094926434587 },
        .variance_alnum_chunk_size = .{ .mean = 0.0, .variance = 0.0 },
        .mean_digit_chunk_size = .{ .mean = 1.0181895093062607, .variance = 0.042040828158416865 },
        .variance_digit_chunk_size = .{ .mean = 0.021503102086858433, .variance = 0.17128238378745675 },
        .vowel_consonant_ratio = .{ .mean = 1.0126903553299493, .variance = 1.9363871782318534 },
        .alpha_chunks = .{ .mean = 2.045685279187817, .variance = 0.04359813445334845 },
        .alnum_chunks = .{ .mean = 1.0, .variance = 0.0 },
        .digit_chunks = .{ .mean = 1.0786802030456852, .variance = 0.0877180550903141 },
        .title_chunks = .{ .mean = 0.0, .variance = 0.0 },
        .mean_letter_frequency_difference = .{ .mean = 0.1677853781611642, .variance = 0.013892307158931324 },
        .variance_letter_frequency_difference = .{ .mean = 0.1802030456852792, .variance = 0.014406758296169683 },
    },
};

// Gaussian probability density: exp(-(x-mean)²/(2*var)) / sqrt(2π*var)
// Returns log probability to avoid underflow; uses tiny epsilon for zero variance.
fn gaussianLogProb(x: f64, mean: f64, variance: f64) f64 {
    const eps = 1e-10;
    const v = @max(variance, eps);
    const diff = x - mean;
    return -0.5 * (diff * diff / v + @log(2.0 * std.math.pi * v));
}

const Features = struct {
    @"+": f64,
    @"-": f64,
    @"_": f64,
    @"/": f64,
    A: f64,
    z: f64,
    Z: f64,
    q: f64,
    Q: f64,
    X: f64,
    x: f64,
    equal: f64,
    length: f64,
    hex: f64,
    lower36: f64,
    upper36: f64,
    base64: f64,
    mean_title_chunk_size: f64,
    variance_title_chunk_size: f64,
    max_title_chunk_size: f64,
    mean_lower_chunk_size: f64,
    variance_lower_chunk_size: f64,
    mean_upper_chunk_size: f64,
    variance_upper_chunk_size: f64,
    mean_alpha_chunk_size: f64,
    variance_alpha_chunk_size: f64,
    mean_alnum_chunk_size: f64,
    variance_alnum_chunk_size: f64,
    mean_digit_chunk_size: f64,
    variance_digit_chunk_size: f64,
    vowel_consonant_ratio: f64,
    alpha_chunks: f64,
    alnum_chunks: f64,
    digit_chunks: f64,
    title_chunks: f64,
    mean_letter_frequency_difference: f64,
    variance_letter_frequency_difference: f64,
};

fn extractFeatures(s: []const u8) Features {
    // character set detection
    var all_hex = true;
    var all_lower36 = true;
    var all_upper36 = true;
    var all_base64 = true;

    // letter frequency counts for feature letters
    var cnt_plus: usize = 0;
    var cnt_minus: usize = 0;
    var cnt_under: usize = 0;
    var cnt_slash: usize = 0;
    var cnt_A: usize = 0;
    var cnt_z: usize = 0;
    var cnt_Z: usize = 0;
    var cnt_q: usize = 0;
    var cnt_Q: usize = 0;
    var cnt_X: usize = 0;
    var cnt_x: usize = 0;
    var cnt_equal: usize = 0;

    // vowel/consonant
    var vowels: usize = 0;
    var consonants: usize = 0;

    for (s) |c| {
        if (!isHexChar(c)) all_hex = false;
        if (!isLower36Char(c)) all_lower36 = false;
        if (!isUpper36Char(c)) all_upper36 = false;
        if (!isBase64Char(c)) all_base64 = false;

        if (c == '+') cnt_plus += 1;
        if (c == '-') cnt_minus += 1;
        if (c == '_') cnt_under += 1;
        if (c == '/') cnt_slash += 1;
        if (c == 'A') cnt_A += 1;
        if (c == 'z') cnt_z += 1;
        if (c == 'Z') cnt_Z += 1;
        if (c == 'q') cnt_q += 1;
        if (c == 'Q') cnt_Q += 1;
        if (c == 'X') cnt_X += 1;
        if (c == 'x') cnt_x += 1;
        if (c == '=') cnt_equal += 1;
        switch (c) {
            'a', 'e', 'i', 'o', 'u', 'A', 'E', 'I', 'O', 'U' => vowels += 1,
            'b'...'d', 'f'...'h', 'j'...'n', 'p'...'t', 'v'...'w', 'y', 'z',
            'B'...'D', 'F'...'H', 'J'...'N', 'P'...'T', 'V'...'W', 'Y', 'Z' => consonants += 1,
            else => {},
        }
    }

    const n = s.len;
    const flen: f64 = @floatFromInt(n);

    // character set totals for ideal frequency
    const charset_total: f64 = if (all_hex) 16.0 else if (all_lower36) 36.0 else if (all_upper36) 36.0 else if (all_base64) 64.0 else 0.0;
    const ideal_freq = if (charset_total > 0) 1.0 / charset_total * flen else 0.0;

    // chunk analysis helpers
    const title_stats = chunkStats(s, .title);
    const lower_stats = chunkStats(s, .lower_chunk);
    const upper_stats = chunkStats(s, .upper_chunk);
    const alpha_stats = chunkStats(s, .alpha);
    const alnum_stats = chunkStats(s, .alnum);
    const digit_stats = chunkStats(s, .digit);

    // letter frequency differences for feature letters.
    // Ruby formula: lfd = abs(count/length - ideal_count) where ideal_count = length/charset_size.
    // Note: this intentionally mixes proportion (count/length) with expected-count (length/charset_size)
    // to match the training data in data.yml which was generated by the Ruby gem.
    const lfd_plus = if (flen > 0) @abs(@as(f64, @floatFromInt(cnt_plus)) / flen - ideal_freq) else 0.0;
    const lfd_minus = if (flen > 0) @abs(@as(f64, @floatFromInt(cnt_minus)) / flen - ideal_freq) else 0.0;
    const lfd_under = if (flen > 0) @abs(@as(f64, @floatFromInt(cnt_under)) / flen - ideal_freq) else 0.0;
    const lfd_slash = if (flen > 0) @abs(@as(f64, @floatFromInt(cnt_slash)) / flen - ideal_freq) else 0.0;
    const lfd_A = if (flen > 0) @abs(@as(f64, @floatFromInt(cnt_A)) / flen - ideal_freq) else 0.0;
    const lfd_z = if (flen > 0) @abs(@as(f64, @floatFromInt(cnt_z)) / flen - ideal_freq) else 0.0;
    const lfd_Z = if (flen > 0) @abs(@as(f64, @floatFromInt(cnt_Z)) / flen - ideal_freq) else 0.0;
    const lfd_q = if (flen > 0) @abs(@as(f64, @floatFromInt(cnt_q)) / flen - ideal_freq) else 0.0;
    const lfd_Q = if (flen > 0) @abs(@as(f64, @floatFromInt(cnt_Q)) / flen - ideal_freq) else 0.0;
    const lfd_X = if (flen > 0) @abs(@as(f64, @floatFromInt(cnt_X)) / flen - ideal_freq) else 0.0;
    const lfd_x = if (flen > 0) @abs(@as(f64, @floatFromInt(cnt_x)) / flen - ideal_freq) else 0.0;

    // mean and max of all letter frequency differences
    const all_lfds = [_]f64{ lfd_plus, lfd_minus, lfd_under, lfd_slash, lfd_A, lfd_z, lfd_Z, lfd_q, lfd_Q, lfd_X, lfd_x };
    var sum_lfd: f64 = 0;
    var max_lfd: f64 = 0;
    for (all_lfds) |v| { sum_lfd += v; if (v > max_lfd) max_lfd = v; }
    const mean_lfd = sum_lfd / @as(f64, @floatFromInt(all_lfds.len));

    const vcr = if (consonants > 0) @as(f64, @floatFromInt(vowels)) / @as(f64, @floatFromInt(consonants)) else @as(f64, @floatFromInt(vowels));

    return .{
        .@"+" = lfd_plus,
        .@"-" = lfd_minus,
        .@"_" = lfd_under,
        .@"/" = lfd_slash,
        .A = lfd_A,
        .z = lfd_z,
        .Z = lfd_Z,
        .q = lfd_q,
        .Q = lfd_Q,
        .X = lfd_X,
        .x = lfd_x,
        .equal = @as(f64, @floatFromInt(cnt_equal)),
        .length = flen,
        .hex = if (all_hex) 1.0 else 0.0,
        .lower36 = if (all_lower36) 1.0 else 0.0,
        .upper36 = if (all_upper36) 1.0 else 0.0,
        .base64 = if (all_base64) 1.0 else 0.0,
        .mean_title_chunk_size = title_stats.mean,
        .variance_title_chunk_size = title_stats.variance,
        .max_title_chunk_size = title_stats.max,
        .mean_lower_chunk_size = lower_stats.mean,
        .variance_lower_chunk_size = lower_stats.variance,
        .mean_upper_chunk_size = upper_stats.mean,
        .variance_upper_chunk_size = upper_stats.variance,
        .mean_alpha_chunk_size = alpha_stats.mean,
        .variance_alpha_chunk_size = alpha_stats.variance,
        .mean_alnum_chunk_size = alnum_stats.mean,
        .variance_alnum_chunk_size = alnum_stats.variance,
        .mean_digit_chunk_size = digit_stats.mean,
        .variance_digit_chunk_size = digit_stats.variance,
        .vowel_consonant_ratio = vcr,
        .alpha_chunks = alpha_stats.count,
        .alnum_chunks = alnum_stats.count,
        .digit_chunks = digit_stats.count,
        .title_chunks = title_stats.count,
        .mean_letter_frequency_difference = mean_lfd,
        .variance_letter_frequency_difference = max_lfd, // Ruby uses max here
    };
}

const ChunkKind = enum { title, lower_chunk, upper_chunk, alpha, alnum, digit };

const ChunkStats = struct { mean: f64, variance: f64, max: f64, count: f64 };

fn chunkStats(s: []const u8, kind: ChunkKind) ChunkStats {
    var lengths: [256]usize = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const start = i;
        switch (kind) {
            .title => {
                if (i < s.len and s[i] >= 'A' and s[i] <= 'Z') {
                    i += 1;
                    while (i < s.len and s[i] >= 'a' and s[i] <= 'z') i += 1;
                    if (i > start + 1) lengths[n] = i - start else { i = start + 1; continue; }
                } else { i += 1; continue; }
            },
            .lower_chunk => {
                if (i < s.len and s[i] >= 'a' and s[i] <= 'z') {
                    while (i < s.len and s[i] >= 'a' and s[i] <= 'z') i += 1;
                    lengths[n] = i - start;
                } else { i += 1; continue; }
            },
            .upper_chunk => {
                if (i < s.len and s[i] >= 'A' and s[i] <= 'Z') {
                    while (i < s.len and s[i] >= 'A' and s[i] <= 'Z') i += 1;
                    lengths[n] = i - start;
                } else { i += 1; continue; }
            },
            .alpha => {
                if (i < s.len and std.ascii.isAlphabetic(s[i])) {
                    while (i < s.len and std.ascii.isAlphabetic(s[i])) i += 1;
                    lengths[n] = i - start;
                } else { i += 1; continue; }
            },
            .alnum => {
                if (i < s.len and std.ascii.isAlphanumeric(s[i])) {
                    while (i < s.len and std.ascii.isAlphanumeric(s[i])) i += 1;
                    lengths[n] = i - start;
                } else { i += 1; continue; }
            },
            .digit => {
                if (i < s.len and std.ascii.isDigit(s[i])) {
                    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
                    lengths[n] = i - start;
                } else { i += 1; continue; }
            },
        }
        if (n < 255) n += 1;
    }
    if (n == 0) return .{ .mean = 0, .variance = 0, .max = 0, .count = 0 };
    var sum: f64 = 0;
    var mx: f64 = 0;
    for (lengths[0..n]) |l| {
        const fl: f64 = @floatFromInt(l);
        sum += fl;
        if (fl > mx) mx = fl;
    }
    const fn_: f64 = @floatFromInt(n);
    const mean = sum / fn_;
    var vsum: f64 = 0;
    for (lengths[0..n]) |l| {
        const d = @as(f64, @floatFromInt(l)) - mean;
        vsum += d * d;
    }
    return .{ .mean = mean, .variance = vsum / fn_, .max = mx, .count = fn_ };
}

fn isHexChar(c: u8) bool { return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F') or c == '-'; }
fn isLower36Char(c: u8) bool { return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z'); }
fn isUpper36Char(c: u8) bool { return (c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z'); }
fn isBase64Char(c: u8) bool { return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '+' or c == '/' or c == '='; }

fn classLogProb(features: Features, class_idx: usize, key_boost: f64) f64 {
    const w = &WEIGHTS[class_idx];
    var log_prob: f64 = @log(1.0 / @as(f64, NUM_CLASSES));
    // multiply in log space for all features
    log_prob += gaussianLogProb(features.@"+", w.@"+".mean, w.@"+".variance);
    log_prob += gaussianLogProb(features.@"-", w.@"-".mean, w.@"-".variance);
    log_prob += gaussianLogProb(features.@"_", w.@"_".mean, w.@"_".variance);
    log_prob += gaussianLogProb(features.@"/", w.@"/".mean, w.@"/".variance);
    log_prob += gaussianLogProb(features.A, w.A.mean, w.A.variance);
    log_prob += gaussianLogProb(features.z, w.z.mean, w.z.variance);
    log_prob += gaussianLogProb(features.Z, w.Z.mean, w.Z.variance);
    log_prob += gaussianLogProb(features.q, w.q.mean, w.q.variance);
    log_prob += gaussianLogProb(features.Q, w.Q.mean, w.Q.variance);
    log_prob += gaussianLogProb(features.X, w.X.mean, w.X.variance);
    log_prob += gaussianLogProb(features.x, w.x.mean, w.x.variance);
    log_prob += gaussianLogProb(features.equal, w.equal.mean, w.equal.variance);
    log_prob += gaussianLogProb(features.length, w.length.mean, w.length.variance);
    log_prob += gaussianLogProb(features.hex, w.hex.mean, w.hex.variance);
    log_prob += gaussianLogProb(features.lower36, w.lower36.mean, w.lower36.variance);
    log_prob += gaussianLogProb(features.upper36, w.upper36.mean, w.upper36.variance);
    log_prob += gaussianLogProb(features.base64, w.base64.mean, w.base64.variance);
    log_prob += gaussianLogProb(features.mean_title_chunk_size, w.mean_title_chunk_size.mean, w.mean_title_chunk_size.variance);
    log_prob += gaussianLogProb(features.variance_title_chunk_size, w.variance_title_chunk_size.mean, w.variance_title_chunk_size.variance);
    log_prob += gaussianLogProb(features.max_title_chunk_size, w.max_title_chunk_size.mean, w.max_title_chunk_size.variance);
    log_prob += gaussianLogProb(features.mean_lower_chunk_size, w.mean_lower_chunk_size.mean, w.mean_lower_chunk_size.variance);
    log_prob += gaussianLogProb(features.variance_lower_chunk_size, w.variance_lower_chunk_size.mean, w.variance_lower_chunk_size.variance);
    log_prob += gaussianLogProb(features.mean_upper_chunk_size, w.mean_upper_chunk_size.mean, w.mean_upper_chunk_size.variance);
    log_prob += gaussianLogProb(features.variance_upper_chunk_size, w.variance_upper_chunk_size.mean, w.variance_upper_chunk_size.variance);
    log_prob += gaussianLogProb(features.mean_alpha_chunk_size, w.mean_alpha_chunk_size.mean, w.mean_alpha_chunk_size.variance);
    log_prob += gaussianLogProb(features.variance_alpha_chunk_size, w.variance_alpha_chunk_size.mean, w.variance_alpha_chunk_size.variance);
    log_prob += gaussianLogProb(features.mean_alnum_chunk_size, w.mean_alnum_chunk_size.mean, w.mean_alnum_chunk_size.variance);
    log_prob += gaussianLogProb(features.variance_alnum_chunk_size, w.variance_alnum_chunk_size.mean, w.variance_alnum_chunk_size.variance);
    log_prob += gaussianLogProb(features.mean_digit_chunk_size, w.mean_digit_chunk_size.mean, w.mean_digit_chunk_size.variance);
    log_prob += gaussianLogProb(features.variance_digit_chunk_size, w.variance_digit_chunk_size.mean, w.variance_digit_chunk_size.variance);
    log_prob += gaussianLogProb(features.vowel_consonant_ratio, w.vowel_consonant_ratio.mean, w.vowel_consonant_ratio.variance);
    log_prob += gaussianLogProb(features.alpha_chunks, w.alpha_chunks.mean, w.alpha_chunks.variance);
    log_prob += gaussianLogProb(features.alnum_chunks, w.alnum_chunks.mean, w.alnum_chunks.variance);
    log_prob += gaussianLogProb(features.digit_chunks, w.digit_chunks.mean, w.digit_chunks.variance);
    log_prob += gaussianLogProb(features.title_chunks, w.title_chunks.mean, w.title_chunks.variance);
    log_prob += gaussianLogProb(features.mean_letter_frequency_difference, w.mean_letter_frequency_difference.mean, w.mean_letter_frequency_difference.variance);
    log_prob += gaussianLogProb(features.variance_letter_frequency_difference, w.variance_letter_frequency_difference.mean, w.variance_letter_frequency_difference.variance);
    // apply heuristic weight boost to key classes: log(10^weight) = weight * ln(10)
    if (isKeyClass(class_idx)) log_prob += key_boost;
    return log_prob;
}

pub fn isKey(s: []const u8, key_heuristic_weight: u32) bool {
    const features = extractFeatures(s);
    const key_boost = @as(f64, @floatFromInt(key_heuristic_weight)) * @log(10.0);
    var best_idx: usize = 0;
    var best_prob: f64 = -std.math.inf(f64);
    for (0..NUM_CLASSES) |i| {
        const p = classLogProb(features, i, key_boost);
        if (p > best_prob) { best_prob = p; best_idx = i; }
    }
    return isKeyClass(best_idx);
}


