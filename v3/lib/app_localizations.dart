import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

enum AppLanguageMode { system, zhHans, zhHant, ja, en }

extension AppLanguageModeValue on AppLanguageMode {
  String get value => switch (this) {
    AppLanguageMode.system => 'system',
    AppLanguageMode.zhHans => 'zh-Hans',
    AppLanguageMode.zhHant => 'zh-Hant',
    AppLanguageMode.ja => 'ja',
    AppLanguageMode.en => 'en',
  };
  Locale? get locale => switch (this) {
    AppLanguageMode.system => null,
    AppLanguageMode.zhHans => const Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hans',
    ),
    AppLanguageMode.zhHant => const Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hant',
    ),
    AppLanguageMode.ja => const Locale('ja'),
    AppLanguageMode.en => const Locale('en'),
  };
  static AppLanguageMode parse(Object? value) =>
      AppLanguageMode.values.firstWhere(
        (mode) => mode.value == value,
        orElse: () => AppLanguageMode.system,
      );
}

class AppLocalizations {
  const AppLocalizations(this.locale);
  final Locale locale;
  static const supportedLocales = <Locale>[
    Locale('en'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    Locale('ja'),
  ];
  static const delegate = _AppLocalizationsDelegate();
  static AppLocalizations of(BuildContext context) =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      const AppLocalizations(
        Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
      );

  static Locale resolve(List<Locale>? preferred, Iterable<Locale> _) {
    for (final locale in preferred ?? const <Locale>[]) {
      final language = locale.languageCode.toLowerCase();
      if (language == 'ja') return const Locale('ja');
      if (language == 'en') return const Locale('en');
      if (language == 'zh') {
        final traditional =
            locale.scriptCode?.toLowerCase() == 'hant' ||
            const {
              'TW',
              'HK',
              'MO',
            }.contains(locale.countryCode?.toUpperCase());
        return Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: traditional ? 'Hant' : 'Hans',
        );
      }
    }
    return const Locale('en');
  }

  String get code => locale.languageCode == 'ja'
      ? 'ja'
      : locale.languageCode != 'zh'
      ? 'en'
      : locale.scriptCode == 'Hant' ||
            const {'TW', 'HK', 'MO'}.contains(locale.countryCode?.toUpperCase())
      ? 'zh-Hant'
      : 'zh-Hans';

  String text(String source) {
    if (source == '雷player' || source == '雷 player' || code == 'zh-Hans')
      return source;
    final exact = _messages[source]?[code];
    if (exact != null) return exact;
    var value = source;
    for (final replacement
        in (code == 'en'
            ? _en
            : code == 'ja'
            ? _ja
            : _hant)) {
      value = value.replaceAll(replacement.$1, replacement.$2);
    }
    return value;
  }

  static const Map<String, Map<String, String>> _messages = {
    '取消': {'zh-Hant': '取消', 'ja': 'キャンセル', 'en': 'Cancel'},
    '确定': {'zh-Hant': '確定', 'ja': '決定', 'en': 'OK'},
    '关闭': {'zh-Hant': '關閉', 'ja': '閉じる', 'en': 'Close'},
    '返回': {'zh-Hant': '返回', 'ja': '戻る', 'en': 'Back'},
    '关闭面板': {'zh-Hant': '關閉面板', 'ja': 'パネルを閉じる', 'en': 'Close panel'},
    '更多操作': {'zh-Hant': '更多操作', 'ja': 'その他の操作', 'en': 'More actions'},
    '设置': {'zh-Hant': '設定', 'ja': '設定', 'en': 'Settings'},
    '让播放器适合你的学习习惯。': {
      'zh-Hant': '讓播放器配合你的學習習慣。',
      'ja': '学習スタイルに合わせて設定します。',
      'en': 'Make the player fit your study habits.',
    },
    '语言': {'zh-Hant': '語言', 'ja': '言語', 'en': 'Language'},
    '跟随系统': {'zh-Hant': '跟隨系統', 'ja': 'システム設定', 'en': 'Follow System'},
    '简体中文': {'zh-Hant': '簡體中文', 'ja': '簡体字中国語', 'en': 'Simplified Chinese'},
    '繁體中文': {'zh-Hant': '繁體中文', 'ja': '繁体字中国語', 'en': 'Traditional Chinese'},
    '日文': {'zh-Hant': '日文', 'ja': '日本語', 'en': 'Japanese'},
    '英语': {'zh-Hant': '英語', 'ja': '英語', 'en': 'English'},
    '选择后全局生效并自动保存。跟随系统会使用系统首选语言，不支持时显示英语。': {
      'zh-Hant': '選擇後會全域生效並自動儲存。跟隨系統會使用系統偏好語言，不支援時顯示英語。',
      'ja': '選択内容はアプリ全体に反映・保存されます。システム設定で未対応の言語は英語になります。',
      'en': 'Your choice applies throughout the app and is saved automatically. Follow System falls back to English for unsupported languages.',
    },
    '外观': {'zh-Hant': '外觀', 'ja': '外観', 'en': 'Appearance'},
    '浅色': {'zh-Hant': '淺色', 'ja': 'ライト', 'en': 'Light'},
    '深色': {'zh-Hant': '深色', 'ja': 'ダーク', 'en': 'Dark'},
    '正在保存…': {'zh-Hant': '正在儲存…', 'ja': '保存中…', 'en': 'Saving…'},
    '选择后立即生效，自动保存。': {
      'zh-Hant': '選擇後立即生效並自動儲存。',
      'ja': '選択するとすぐ反映され、自動保存されます。',
      'en': 'Applies immediately and saves automatically.',
    },
    '播放': {'zh-Hant': '播放', 'ja': '再生', 'en': 'Play'},
    '暂停': {'zh-Hant': '暫停', 'ja': '一時停止', 'en': 'Pause'},
    '取消加载': {'zh-Hant': '取消載入', 'ja': '読み込みをキャンセル', 'en': 'Cancel loading'},
    '记住播放进度': {
      'zh-Hant': '記住播放進度',
      'ja': '再生位置を記憶',
      'en': 'Remember playback position',
    },
    '下次打开，从上次停下的位置继续': {
      'zh-Hant': '下次開啟時，從上次停止的位置繼續',
      'ja': '次回、前回停止した位置から再開します',
      'en': 'Resume where you stopped next time',
    },
    '智能跳过空白片头': {
      'zh-Hant': '智慧跳過空白片頭',
      'ja': '無音の冒頭を自動スキップ',
      'en': 'Smart intro skip',
    },
    '仅跳过同时黑屏且静音的开头': {
      'zh-Hant': '僅跳過同時黑畫面且靜音的開頭',
      'ja': '黒画面かつ無音の冒頭だけをスキップします',
      'en': 'Only skip intros that are both black and silent',
    },
    '自动连续播放': {'zh-Hant': '自動連續播放', 'ja': '連続再生', 'en': 'Continuous playback'},
    '当前课程结束后，接着播放队列': {
      'zh-Hant': '目前課程結束後，接著播放佇列',
      'ja': '現在のレッスン終了後もキューを再生します',
      'en': 'Continue through the queue after the current lesson',
    },
    '后退秒数': {'zh-Hant': '後退秒數', 'ja': '巻き戻し秒数', 'en': 'Rewind seconds'},
    '前进秒数': {'zh-Hant': '前進秒數', 'ja': '早送り秒数', 'en': 'Forward seconds'},
    '后台与中断': {
      'zh-Hant': '背景與中斷',
      'ja': 'バックグラウンドと中断',
      'en': 'Background & Interruptions',
    },
    '后台播放始终开启': {
      'zh-Hant': '背景播放一律開啟',
      'ja': 'バックグラウンド再生は常に有効です',
      'en': 'Background playback is always on',
    },
    '中断恢复': {
      'zh-Hant': '中斷恢復',
      'ja': '中断後に再開',
      'en': 'Resume after interruption',
    },
    '通话结束后尝试恢复播放': {
      'zh-Hant': '通話結束後嘗試恢復播放',
      'ja': '通話終了後に再生を再開します',
      'en': 'Try to resume after a call ends',
    },
    '文件与记录': {'zh-Hant': '檔案與記錄', 'ja': 'ファイルと履歴', 'en': 'Files & History'},
    '回收站': {'zh-Hant': '垃圾桶', 'ja': 'ゴミ箱', 'en': 'Trash'},
    '找回已移除的文件': {
      'zh-Hant': '找回已移除的檔案',
      'ja': '削除したファイルを復元',
      'en': 'Recover removed files',
    },
    '清除播放历史': {
      'zh-Hant': '清除播放記錄',
      'ja': '再生履歴を消去',
      'en': 'Clear playback history',
    },
    '保留收藏和媒体文件': {
      'zh-Hant': '保留收藏與媒體檔案',
      'ja': 'お気に入りとメディアを保持',
      'en': 'Keep favorites and media files',
    },
    '支持开发': {'zh-Hant': '支持開發', 'ja': '開発を支援', 'en': 'Support Development'},
    '打赏开发者': {
      'zh-Hant': '贊助開發者',
      'ja': '開発者を支援',
      'en': 'Support the Developer',
    },
    '关于雷player': {
      'zh-Hant': '關於雷player',
      'ja': '雷player について',
      'en': 'About 雷player',
    },
    '隐私政策': {'zh-Hant': '隱私權政策', 'ja': 'プライバシーポリシー', 'en': 'Privacy Policy'},
    '开源软件许可': {
      'zh-Hant': '開放原始碼軟體授權',
      'ja': 'オープンソースライセンス',
      'en': 'Open-source Licenses',
    },
    '版权与用户内容': {
      'zh-Hant': '版權與使用者內容',
      'ja': '著作権とユーザーコンテンツ',
      'en': 'Copyright & User Content',
    },
    '添加课程': {'zh-Hant': '新增課程', 'ja': 'コースを追加', 'en': 'Add Course'},
    '选择导入方式，或先建立课程文件夹。': {
      'zh-Hant': '選擇匯入方式，或先建立課程資料夾。',
      'ja': '読み込み方法を選ぶか、コースフォルダを作成します。',
      'en': 'Choose an import method, or create a course folder first.',
    },
    '导入课程文件夹': {
      'zh-Hant': '匯入課程資料夾',
      'ja': 'コースフォルダを読み込む',
      'en': 'Import Course Folder',
    },
    '保留课程目录与子文件夹': {
      'zh-Hant': '保留課程目錄與子資料夾',
      'ja': 'コース構成とサブフォルダを保持',
      'en': 'Keep course structure and subfolders',
    },
    '选择媒体文件': {
      'zh-Hant': '選擇媒體檔案',
      'ja': 'メディアファイルを選択',
      'en': 'Choose Media Files',
    },
    '视频、音频及外置字幕': {
      'zh-Hant': '影片、音訊及外掛字幕',
      'ja': '動画、音声、外部字幕',
      'en': 'Video, audio, and external subtitles',
    },
    '新建文件夹': {'zh-Hant': '新增資料夾', 'ja': '新規フォルダ', 'en': 'New Folder'},
    '按课程或章节整理内容': {
      'zh-Hant': '依課程或章節整理內容',
      'ja': 'コースや章ごとに整理',
      'en': 'Organize by course or chapter',
    },
    '重命名（请保留文件扩展名）': {
      'zh-Hant': '重新命名（請保留副檔名）',
      'ja': '名前を変更（拡張子は残してください）',
      'en': 'Rename (keep the file extension)',
    },
    '移动到文件夹': {'zh-Hant': '移動到資料夾', 'ja': 'フォルダへ移動', 'en': 'Move to Folder'},
    '选择目标目录': {'zh-Hant': '選擇目標目錄', 'ja': '移動先を選択', 'en': 'Choose Destination'},
    '课程库根目录': {
      'zh-Hant': '課程庫根目錄',
      'ja': 'コースライブラリのルート',
      'en': 'Course Library Root',
    },
    '移入回收站？': {
      'zh-Hant': '移到垃圾桶？',
      'ja': 'ゴミ箱へ移動しますか？',
      'en': 'Move to Trash?',
    },
    '回收站为空': {'zh-Hant': '垃圾桶是空的', 'ja': 'ゴミ箱は空です', 'en': 'Trash is Empty'},
    '清空回收站': {'zh-Hant': '清空垃圾桶', 'ja': 'ゴミ箱を空にする', 'en': 'Empty Trash'},
    '永久删除？': {
      'zh-Hant': '永久刪除？',
      'ja': '完全に削除しますか？',
      'en': 'Delete Permanently?',
    },
    '列表': {'zh-Hant': '列表', 'ja': 'リスト', 'en': 'List'},
    '网格': {'zh-Hant': '格狀', 'ja': 'グリッド', 'en': 'Grid'},
    '名称': {'zh-Hant': '名稱', 'ja': '名前', 'en': 'Name'},
    '类型': {'zh-Hant': '類型', 'ja': '種類', 'en': 'Type'},
    '大小': {'zh-Hant': '大小', 'ja': 'サイズ', 'en': 'Size'},
    '日期': {'zh-Hant': '日期', 'ja': '日付', 'en': 'Date'},
    '课程库': {'zh-Hant': '課程庫', 'ja': 'コース', 'en': 'Library'},
    '最近播放': {'zh-Hant': '最近播放', 'ja': '最近の再生', 'en': 'Recent'},
    '我的收藏': {'zh-Hant': '我的收藏', 'ja': 'お気に入り', 'en': 'Favorites'},
    '继续学习': {'zh-Hant': '繼續學習', 'ja': '学習を続ける', 'en': 'Continue Learning'},
    '当前课程': {'zh-Hant': '目前課程', 'ja': '現在のレッスン', 'en': 'Current Lesson'},
    '返回播放': {'zh-Hant': '返回播放', 'ja': '再生に戻る', 'en': 'Return to Playback'},
    '继续播放': {'zh-Hant': '繼續播放', 'ja': '再生を続ける', 'en': 'Continue Playing'},
    '正在读取课程…': {
      'zh-Hant': '正在讀取課程…',
      'ja': 'コースを読み込み中…',
      'en': 'Loading courses…',
    },
    '还没有播放记录': {
      'zh-Hant': '尚無播放記錄',
      'ja': '再生履歴はまだありません',
      'en': 'No playback history yet',
    },
    '还没有收藏': {
      'zh-Hant': '尚無收藏',
      'ja': 'お気に入りはまだありません',
      'en': 'No favorites yet',
    },
    '当前文件夹为空': {
      'zh-Hant': '目前資料夾是空的',
      'ja': 'このフォルダは空です',
      'en': 'This folder is empty',
    },
    '收藏': {'zh-Hant': '收藏', 'ja': 'お気に入りに追加', 'en': 'Favorite'},
    '取消收藏': {'zh-Hant': '取消收藏', 'ja': 'お気に入りから削除', 'en': 'Remove Favorite'},
    '从头播放': {'zh-Hant': '從頭播放', 'ja': '最初から再生', 'en': 'Play from Beginning'},
    '重命名': {'zh-Hant': '重新命名', 'ja': '名前を変更', 'en': 'Rename'},
    '移动': {'zh-Hant': '移動', 'ja': '移動', 'en': 'Move'},
    '文件信息': {'zh-Hant': '檔案資訊', 'ja': 'ファイル情報', 'en': 'File Info'},
    '移入回收站': {'zh-Hant': '移到垃圾桶', 'ja': 'ゴミ箱へ移動', 'en': 'Move to Trash'},
    '播放进度': {'zh-Hant': '播放進度', 'ja': '再生位置', 'en': 'Playback progress'},
    '播放队列': {'zh-Hant': '播放佇列', 'ja': '再生キュー', 'en': 'Play Queue'},
    '播放速度': {'zh-Hant': '播放速度', 'ja': '再生速度', 'en': 'Playback Speed'},
    '顺序播放': {'zh-Hant': '依序播放', 'ja': '順番に再生', 'en': 'Sequential'},
    '文件夹循环': {'zh-Hant': '資料夾循環', 'ja': 'フォルダをリピート', 'en': 'Repeat Folder'},
    '单集循环': {'zh-Hant': '單集循環', 'ja': '1項目をリピート', 'en': 'Repeat One'},
    '随机播放': {'zh-Hant': '隨機播放', 'ja': 'シャッフル', 'en': 'Shuffle'},
    '播放信息': {'zh-Hant': '播放資訊', 'ja': '再生情報', 'en': 'Playback Info'},
    '复制信息': {'zh-Hant': '複製資訊', 'ja': '情報をコピー', 'en': 'Copy Info'},
    '音轨与字幕': {'zh-Hant': '音軌與字幕', 'ja': '音声と字幕', 'en': 'Audio & Subtitles'},
    '关闭字幕': {'zh-Hant': '關閉字幕', 'ja': '字幕をオフ', 'en': 'Subtitles Off'},
    '播放选项': {'zh-Hant': '播放選項', 'ja': '再生オプション', 'en': 'Playback Options'},
    '上一节': {'zh-Hant': '上一節', 'ja': '前のレッスン', 'en': 'Previous'},
    '下一节': {'zh-Hant': '下一節', 'ja': '次のレッスン', 'en': 'Next'},
    '画面比例': {'zh-Hant': '畫面比例', 'ja': '画面サイズ', 'en': 'Aspect Ratio'},
    '适应画面': {'zh-Hant': '適應畫面', 'ja': '画面に合わせる', 'en': 'Fit'},
    '填满画面': {'zh-Hant': '填滿畫面', 'ja': '画面を埋める', 'en': 'Fill'},
    '拉伸画面': {'zh-Hant': '拉伸畫面', 'ja': '引き伸ばす', 'en': 'Stretch'},
    'A–B 片段复读': {'zh-Hant': 'A–B 片段重複', 'ja': 'A–B リピート', 'en': 'A–B Repeat'},
    '音量与亮度': {'zh-Hant': '音量與亮度', 'ja': '音量と明るさ', 'en': 'Volume & Brightness'},
    '当前播放状态': {
      'zh-Hant': '目前播放狀態',
      'ja': '現在の再生状態',
      'en': 'Current Playback Status',
    },
    '播放音量': {'zh-Hant': '播放音量', 'ja': '再生音量', 'en': 'Playback Volume'},
    '屏幕亮度': {'zh-Hant': '螢幕亮度', 'ja': '画面の明るさ', 'en': 'Screen Brightness'},
    '定时停止': {'zh-Hant': '定時停止', 'ja': 'スリープタイマー', 'en': 'Sleep Timer'},
    '快捷选择': {'zh-Hant': '快速選擇', 'ja': 'クイック選択', 'en': 'Quick Select'},
    '分钟': {'zh-Hant': '分鐘', 'ja': '分', 'en': 'minutes'},
    '开始计时': {'zh-Hant': '開始計時', 'ja': 'タイマーを開始', 'en': 'Start Timer'},
    '亮度': {'zh-Hant': '亮度', 'ja': '明るさ', 'en': 'Brightness'},
    '音量': {'zh-Hant': '音量', 'ja': '音量', 'en': 'Volume'},
    '暂时无法播放': {'zh-Hant': '暫時無法播放', 'ja': '現在再生できません', 'en': 'Unable to Play'},
    '重试播放': {'zh-Hant': '重試播放', 'ja': '再試行', 'en': 'Retry Playback'},
    '返回课程库': {'zh-Hant': '返回課程庫', 'ja': 'コースに戻る', 'en': 'Back to Library'},
    '锁定控件': {'zh-Hant': '鎖定控制項', 'ja': 'コントロールをロック', 'en': 'Lock Controls'},
    '解锁控件': {'zh-Hant': '解鎖控制項', 'ja': 'ロックを解除', 'en': 'Unlock Controls'},
    '画中画': {
      'zh-Hant': '子母畫面',
      'ja': 'ピクチャ・イン・ピクチャ',
      'en': 'Picture in Picture',
    },
    '横竖屏': {'zh-Hant': '橫直螢幕', 'ja': '画面を回転', 'en': 'Rotate Screen'},
    '隐藏控件': {'zh-Hant': '隱藏控制項', 'ja': 'コントロールを隠す', 'en': 'Hide Controls'},
    '感谢你的支持': {
      'zh-Hant': '感謝你的支持',
      'ja': 'ご支援ありがとうございます',
      'en': 'Thank You for Your Support',
    },
    '正在加载商品…': {
      'zh-Hant': '正在載入商品…',
      'ja': '商品を読み込み中…',
      'en': 'Loading products…',
    },
    '重新加载商品': {'zh-Hant': '重新載入商品', 'ja': '商品を再読み込み', 'en': 'Reload Products'},
    '一份鼓励': {'zh-Hant': '一份鼓勵', 'ja': 'ひとつの応援', 'en': 'A Little Support'},
    '暖心支持': {'zh-Hant': '暖心支持', 'ja': 'あたたかい応援', 'en': 'Warm Support'},
    '特别支持': {'zh-Hant': '特別支持', 'ja': '特別な応援', 'en': 'Special Support'},
    '大力支持': {'zh-Hant': '大力支持', 'ja': '力強い応援', 'en': 'Big Support'},
    '顶级鼓励': {'zh-Hant': '頂級鼓勵', 'ja': '最高の応援', 'en': 'Top Support'},
    '夯': {'zh-Hant': '夯', 'ja': '全力応援', 'en': 'Ultimate Support'},
    '跳过': {'zh-Hant': '跳過', 'ja': 'スキップ', 'en': 'Skip'},
    '导入会复制到 App 课程目录，原文件保留；重名文件自动编号。': {'zh-Hant':'匯入內容會複製到 App 課程目錄，原始檔案會保留；同名檔案會自動編號。','ja':'読み込んだ内容はアプリのコースフォルダへコピーされ、元ファイルは保持されます。同名ファイルには番号が付きます。','en':'Imports are copied into the app course directory. Originals are kept and duplicate names are numbered.'},
    '按删除时间排列，点击文件即可恢复到原位置': {'zh-Hant':'依刪除時間排列，點選檔案即可還原到原位置','ja':'削除日時順です。ファイルをタップすると元の場所へ復元します','en':'Sorted by deletion time. Tap a file to restore it.'},
    '移除的文件会暂存于此': {'zh-Hant':'移除的檔案會暫存在這裡','ja':'削除したファイルはここに一時保存されます','en':'Removed files are kept here temporarily'},
    '异常回收项目': {'zh-Hant':'異常的垃圾桶項目','ja':'破損したゴミ箱項目','en':'Invalid trash item'},
    '原路径或文件信息已损坏，可通过清空回收站删除': {'zh-Hant':'原始路徑或檔案資訊已損壞，可透過清空垃圾桶刪除','ja':'元のパスまたはファイル情報が壊れています。ゴミ箱を空にすると削除できます','en':'The original path or file information is damaged. Empty Trash to remove it.'},
    '回收站内所有文件将永久删除，无法恢复。': {'zh-Hant':'垃圾桶內所有檔案將永久刪除，無法還原。','ja':'ゴミ箱内の全ファイルが完全に削除され、復元できません。','en':'Every file in Trash will be permanently deleted and cannot be recovered.'},
    '关闭进度记忆后从头播放，已有记录保留。断点续播优先于片头跳过；倍速与循环模式可在播放页调整。': {'zh-Hant':'關閉進度記憶後會從頭播放，既有記錄仍會保留。斷點續播優先於片頭跳過；倍速與循環模式可在播放頁調整。','ja':'再生位置の記憶をオフにすると最初から再生します。既存の履歴は保持されます。再開位置は冒頭スキップより優先され、速度とリピートは再生画面で変更できます。','en':'When position memory is off, playback starts at the beginning; existing records remain. Resume takes priority over intro skip. Speed and repeat are adjusted on the playback screen.'},
    '仅在中断前正在播放、且 iOS 允许时恢复。': {'zh-Hant':'僅在中斷前正在播放且 iOS 允許時恢復。','ja':'中断前に再生中で、iOS が許可する場合だけ再開します。','en':'Resumes only if playback was active before the interruption and iOS allows it.'},
    '清除历史？': {'zh-Hant':'清除記錄？','ja':'履歴を消去しますか？','en':'Clear History?'},
    '收藏和视频文件保留；开启“记住播放进度”时会重新记录当前进度。': {'zh-Hant':'收藏和影片檔案會保留；開啟「記住播放進度」時會重新記錄目前進度。','ja':'お気に入りと動画ファイルは保持されます。「再生位置を記憶」が有効なら現在位置が再び記録されます。','en':'Favorites and media files are kept. Current position will be recorded again when Remember Playback Position is enabled.'},
    '打赏为可重复购买的消耗型项目，完全自愿且不可恢复；雷player 始终免费、无广告。': {'zh-Hant':'贊助是可重複購買的消耗型項目，完全自願且不可恢復；雷player 永遠免費且無廣告。','ja':'支援は繰り返し購入できる任意の消耗型アイテムで、復元できません。雷player は常に無料・広告なしです。','en':'Tips are optional, repeatable consumable purchases and cannot be restored. 雷player remains free and ad-free.'},
    '专注本地课程，陪你随时进入学习。\n爱学习的人最可爱。\n每天多学一点，未来就多一种可能。\n慢一点也没关系，坚持的每一步都算数。\n愿雷player陪你保持好奇，不断成长。': {'zh-Hant':'專注本機課程，陪你隨時進入學習。\n愛學習的人最可愛。\n每天多學一點，未來就多一種可能。\n慢一點也沒關係，堅持的每一步都算數。\n願雷player陪你保持好奇，不斷成長。','ja':'ローカルのコースに集中し、いつでも学習を始められます。\n学ぶ人はすてきです。\n毎日少しずつ学べば、未来の可能性が広がります。\nゆっくりでも、一歩ずつ続けることが大切です。\n雷player と一緒に好奇心を持ち、成長を続けましょう。','en':'Focus on local courses and start learning anytime.\nPeople who love learning are wonderful.\nLearn a little each day and open more possibilities.\nGoing slowly is fine; every steady step counts.\nStay curious and keep growing with 雷player.'},
    '文件存于 App 自有目录，可通过系统“文件”或 Finder 文件共享管理。卸载 App 会移除其数据，请保留课程原文件。': {'zh-Hant':'檔案儲存在 App 自有目錄，可透過系統「檔案」或 Finder 檔案分享管理。解除安裝 App 會移除其資料，請保留課程原始檔案。','ja':'ファイルはアプリ専用フォルダに保存され、システムの「ファイル」または Finder のファイル共有で管理できます。アプリを削除するとデータも消えるため、元のコースファイルを保管してください。','en':'Files are stored in the app container and can be managed through Files or Finder File Sharing. Uninstalling removes app data, so keep the original course files.'},
    '使用 iOS 系统播放能力，实际格式兼容与流畅度取决于编码、系统版本和设备。支持外置 SRT / VTT；外置字幕不会显示在系统画中画中。': {'zh-Hant':'使用 iOS 系統播放能力，實際格式相容性與流暢度取決於編碼、系統版本和裝置。支援外掛 SRT / VTT；外掛字幕不會顯示在系統子母畫面中。','ja':'iOS の再生機能を使用します。形式の互換性と滑らかさはエンコード、OS、端末に依存します。外部 SRT / VTT に対応しますが、システムのピクチャ・イン・ピクチャには表示されません。','en':'Playback uses iOS capabilities. Format compatibility and performance depend on encoding, OS version, and device. External SRT/VTT is supported but does not appear in system Picture in Picture.'},
    '本地数据处理、保留与联系信息': {'zh-Hant':'本機資料處理、保留與聯絡資訊','ja':'ローカルデータの処理、保持、連絡先','en':'Local data handling, retention, and contact information'},
    'Flutter、Dart 与原生播放器版权、源码及许可证': {'zh-Hant':'Flutter、Dart 與原生播放器的版權、原始碼及授權','ja':'Flutter、Dart、ネイティブプレーヤーの著作権、ソース、ライセンス','en':'Flutter, Dart, and native player copyrights, source, and licenses'},
    '版权所有者、用户责任与合规联系': {'zh-Hant':'版權所有者、使用者責任與法令遵循聯絡方式','ja':'権利者、ユーザー責任、コンプライアンス窓口','en':'Rights holders, user responsibilities, and compliance contact'},
    '通过右上角菜单导入课程或新建文件夹。': {'zh-Hant':'透過右上角選單匯入課程或新增資料夾。','ja':'右上のメニューからコースの読み込みやフォルダ作成ができます。','en':'Use the top-right menu to import courses or create a folder.'},
    '播放过的课程会出现在这里。': {'zh-Hant':'播放過的課程會顯示在這裡。','ja':'再生したレッスンがここに表示されます。','en':'Lessons you play will appear here.'},
    '在文件菜单或播放页中添加收藏。': {'zh-Hant':'在檔案選單或播放頁加入收藏。','ja':'ファイルメニューまたは再生画面でお気に入りに追加できます。','en':'Add favorites from a file menu or the playback screen.'},
    '播放将在设定时间后自动停止': {'zh-Hant':'播放將在設定時間後自動停止','ja':'設定時間後に再生を自動停止します','en':'Playback will stop after the selected time'},
    '请输入 1～1440 之间的整数': {'zh-Hant':'請輸入 1～1440 之間的整數','ja':'1～1440 の整数を入力してください','en':'Enter a whole number from 1 to 1440'},
    '1～1440 分钟 · 最长 24 小时': {'zh-Hant':'1～1440 分鐘 · 最長 24 小時','ja':'1～1440 分 · 最大24時間','en':'1–1440 minutes · up to 24 hours'},
    '队列为空，请返回课程库选择媒体。': {'zh-Hant':'佇列是空的，請返回課程庫選擇媒體。','ja':'キューは空です。コースへ戻ってメディアを選択してください。','en':'The queue is empty. Return to the library and choose media.'},
    '课程已切换，请重新打开队列': {'zh-Hant':'課程已切換，請重新開啟佇列','ja':'レッスンが変わりました。キューを開き直してください','en':'The lesson changed. Reopen the queue.'},
    '已复制完整播放信息': {'zh-Hant':'已複製完整播放資訊','ja':'再生情報をコピーしました','en':'Full playback information copied'},
    '复制失败，请重试': {'zh-Hant':'複製失敗，請再試一次','ja':'コピーできませんでした。再試行してください','en':'Copy failed. Try again.'},
    '请先回课程库，通过 + 导入字幕文件': {'zh-Hant':'請先返回課程庫，透過 + 匯入字幕檔案','ja':'コースへ戻り、+ から字幕ファイルを読み込んでください','en':'Return to the library and use + to import a subtitle file.'},
    '媒体已变化，请关闭后重新选择': {'zh-Hant':'媒體已變更，請關閉後重新選擇','ja':'メディアが変わりました。閉じて選び直してください','en':'The media changed. Close and choose again.'},
    '正在确认轨道切换…': {'zh-Hant':'正在確認軌道切換…','ja':'トラック切替を確認中…','en':'Confirming track change…'},
    '暂未发现轨道': {'zh-Hant':'尚未找到軌道','ja':'トラックが見つかりません','en':'No tracks found'},
    '在起点设置 A，播放到终点设置 B。也可先关闭面板，拖动进度后再设置。切换媒体会清除复读区间。': {'zh-Hant':'在起點設定 A，播放到終點設定 B。也可先關閉面板，拖動進度後再設定。切換媒體會清除重複區間。','ja':'開始位置で A、終了位置で B を設定します。パネルを閉じて位置を移動してから設定することもできます。メディアを切り替えると範囲は消去されます。','en':'Set A at the start and B at the end. You can close the panel, seek, and set the point later. Changing media clears the repeat range.'},
    '播放画面左侧上下滑动调音量，右侧上下滑动调亮度；数值会自动保存。退出播放页面后恢复原屏幕亮度，系统音量仍可用手机音量键调整。': {'zh-Hant':'在播放畫面左側上下滑動調整音量，右側上下滑動調整亮度；數值會自動儲存。離開播放頁後會恢復原螢幕亮度，系統音量仍可用手機音量鍵調整。','ja':'再生画面の左側を上下にスワイプして音量、右側で明るさを調整します。値は自動保存されます。画面を閉じると元の明るさに戻り、システム音量は端末ボタンでも変更できます。','en':'Swipe vertically on the left of the video for volume and on the right for brightness. Values save automatically. Screen brightness is restored when leaving playback; system volume remains adjustable with device buttons.'},
    '音频中断中，等待通话结束…': {'zh-Hant':'音訊已中斷，正在等待通話結束…','ja':'音声が中断されています。通話終了を待っています…','en':'Audio interrupted; waiting for the call to end…'},
    '正在识别空白片头…': {'zh-Hant':'正在辨識空白片頭…','ja':'無音の冒頭を検出中…','en':'Detecting a blank intro…'},
    '你的每一份鼓励，都是雷player不断完善的动力。': {'zh-Hant':'你的每一份鼓勵，都是雷player不斷完善的動力。','ja':'一つひとつの応援が、雷player をより良くする力になります。','en':'Every bit of support helps make 雷player better.'},
    '打赏完全自愿，是一次性、可重复购买的 App Store 消耗型项目；不解锁任何功能或内容，不影响免费使用，且不可恢复。': {'zh-Hant':'贊助完全自願，是一次性、可重複購買的 App Store 消耗型項目；不會解鎖任何功能或內容，不影響免費使用，且不可恢復。','ja':'支援は完全に任意の App Store 消耗型購入で、繰り返し購入できます。機能やコンテンツは解放されず、無料利用に影響せず、復元できません。','en':'Tips are entirely optional, repeatable App Store consumable purchases. They unlock no features or content, do not affect free use, and cannot be restored.'},
    '暂未获取到商品，请稍后重试': {'zh-Hant':'暫時無法取得商品，請稍後再試','ja':'商品を取得できません。後でもう一度お試しください','en':'Products are unavailable. Try again later.'},
    '部分商品暂不可用，请稍后重试。': {'zh-Hant':'部分商品暫時無法使用，請稍後再試。','ja':'一部の商品は現在利用できません。後でもう一度お試しください。','en':'Some products are temporarily unavailable. Try again later.'},
    '当前设备不允许购买。': {'zh-Hant':'目前裝置不允許購買。','ja':'この端末では購入できません。','en':'Purchases are not allowed on this device.'},
    '愿每一份热爱都有回响。': {'zh-Hant':'願每一份熱愛都有回響。','ja':'すべての情熱が実を結びますように。','en':'May every passion find its echo.'},
    '第三方组件适用各自许可证；联系邮箱：32661267@qq.com': {'zh-Hant':'第三方元件適用各自授權；聯絡信箱：32661267@qq.com','ja':'第三者コンポーネントには各ライセンスが適用されます。連絡先：32661267@qq.com','en':'Third-party components are governed by their respective licenses. Contact: 32661267@qq.com'},
  };

  static const _en = <(String, String)>[
    ('正在保存', 'Saving'),
    ('正在加载', 'Loading'),
    ('当前剩余', 'Remaining '),
    ('请稍后重试', 'Please try again later'),
    ('无法', 'Unable to '),
    ('失败', ' failed'),
    ('已复制', 'Copied '),
    ('已导入', 'Imported '),
    (' 项', ' items'),
    (' 分钟', ' min'),
    (' 小时', ' hr'),
    (' 秒', ' sec'),
    ('当前', 'Current '),
    ('播放', 'Playback'),
    ('音轨', 'Audio track'),
    ('字幕', 'Subtitle'),
    ('未知', 'Unknown'),
    ('文件夹', 'folder'),
    ('课程', 'lesson'),
    ('关闭', 'Close'),
    ('返回', 'Back'),
    ('选择', 'Choose '),
    ('设置', 'Set '),
    ('更多', 'More '),
    ('路径：', 'Path: '),
    ('类型：', 'Type: '),
    ('大小：', 'Size: '),
    ('修改时间：', 'Modified: '),
    ('可重新设置或关闭', ' · reset or turn it off'),
    ('个媒体 · 按课程顺序播放', ' media items · course order'),
    ('上次播至', 'Last played at '),
    ('尚未记录进度', 'No saved position'),
    ('第 ', 'Lesson '),
    (' 节', ''),
    ('当前位置', 'Current position '),
    ('A 点', 'Point A'),
    ('B 点', 'Point B'),
    ('后退', 'Rewind'),
    ('前进', 'Forward'),
    ('感谢你的「', 'Thank you for “'),
    ('」！', '” support!'),
  ];
  static const _ja = <(String, String)>[
    ('正在保存', '保存中'),
    ('正在加载', '読み込み中'),
    ('当前剩余', '残り '),
    ('请稍后重试', '後でもう一度お試しください'),
    ('无法', 'できません：'),
    ('失败', '失敗'),
    ('已复制', 'コピー済み '),
    ('已导入', '読み込み済み '),
    (' 项', ' 件'),
    (' 分钟', ' 分'),
    (' 小时', ' 時間'),
    (' 秒', ' 秒'),
    ('当前', '現在の'),
    ('播放', '再生'),
    ('音轨', '音声'),
    ('字幕', '字幕'),
    ('未知', '不明'),
    ('文件夹', 'フォルダ'),
    ('课程', 'レッスン'),
    ('关闭', '閉じる'),
    ('返回', '戻る'),
    ('选择', '選択'),
    ('设置', '設定'),
    ('路径：', 'パス：'),
    ('类型：', '種類：'),
    ('大小：', 'サイズ：'),
    ('修改时间：', '更新日時：'),
    ('可重新设置或关闭', '・再設定または停止できます'),
    ('个媒体 · 按课程顺序播放', ' 件・コース順に再生'),
    ('上次播至', '前回の位置 '),
    ('尚未记录进度', '再生位置なし'),
    ('第 ', '第'),
    (' 节', ' 回'),
    ('当前位置', '現在位置 '),
    ('后退', '巻き戻し'),
    ('前进', '早送り'),
    ('感谢你的「', '「'),
    ('」！', '」のご支援ありがとうございます！'),
  ];
  static const _hant = <(String, String)>[
    ('设置', '設定'),
    ('选择', '選擇'),
    ('课程', '課程'),
    ('文件', '檔案'),
    ('导入', '匯入'),
    ('目录', '目錄'),
    ('后', '後'),
    ('进', '進'),
    ('开', '開'),
    ('关', '關'),
    ('复', '複'),
    ('记', '記'),
    ('录', '錄'),
    ('频', '頻'),
    ('时', '時'),
    ('间', '間'),
    ('过', '過'),
    ('为', '為'),
    ('显', '顯'),
    ('动', '動'),
    ('页', '頁'),
    ('继续', '繼續'),
    ('当前', '目前'),
    ('无法', '無法'),
    ('请', '請'),
    ('发', '發'),
    ('态', '態'),
    ('声', '聲'),
    ('长', '長'),
  ];
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();
  @override
  bool isSupported(Locale locale) =>
      const {'en', 'zh', 'ja'}.contains(locale.languageCode);
  @override
  Future<AppLocalizations> load(Locale locale) =>
      SynchronousFuture(AppLocalizations(locale));
  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

class LText extends StatelessWidget {
  const LText(
    this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.textDirection,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  });
  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final Color? selectionColor;
  @override
  Widget build(BuildContext context) => Text(
    AppLocalizations.of(context).text(data),
    style: style,
    textAlign: textAlign,
    textDirection: textDirection,
    softWrap: softWrap,
    overflow: overflow,
    textScaler: textScaler,
    maxLines: maxLines,
    semanticsLabel: semanticsLabel == null
        ? null
        : AppLocalizations.of(context).text(semanticsLabel!),
    textWidthBasis: textWidthBasis,
    textHeightBehavior: textHeightBehavior,
    selectionColor: selectionColor,
  );
}

class LSelectableText extends StatelessWidget {
  const LSelectableText(this.data, {super.key, this.style, this.textAlign});
  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  @override
  Widget build(BuildContext context) => SelectableText(
    AppLocalizations.of(context).text(data),
    style: style,
    textAlign: textAlign,
  );
}
