import 'package:flutter_test/flutter_test.dart';
import 'package:qinglong_flutter/features/ai/agent/agent_loop.dart';

/// 追问链：第 3、第 4 个问题不能改成"写在正文里"。
///
/// 现场故障：前两轮老老实实调 ask_user，第三轮直接在正文里写"要跑什么命令？"，
/// 界面上没有提问卡也不挂起，用户以为工具被省掉了。循环靠
/// [AgentLoop.looksLikePlainQuestion] 认出这种正文，把模型拽回工具。
void main() {
  group('looksLikePlainQuestion', () {
    test('正文末尾在问话 → 判为提问', () {
      expect(AgentLoop.looksLikePlainQuestion('好的，那要跑的命令是什么？'), isTrue);
      expect(AgentLoop.looksLikePlainQuestion('cron 我记下了。请告诉我脚本名'), isTrue);
      expect(AgentLoop.looksLikePlainQuestion('两种做法，你想用哪一个'), isTrue);
      // 半角问号同样算。
      expect(AgentLoop.looksLikePlainQuestion('which script?'), isTrue);
    });

    test('普通结论不算提问', () {
      expect(AgentLoop.looksLikePlainQuestion('任务已经建好了，明早 8 点会跑。'), isFalse);
      expect(AgentLoop.looksLikePlainQuestion(''), isFalse);
      expect(AgentLoop.looksLikePlainQuestion('   '), isFalse);
    });

    test('中间引用了带问号的报错，但结尾是结论 → 不算提问', () {
      const text = '日志里那句 "Cannot find module?" 是依赖没装，'
          '我已经用 dep_add 装上了 axios，重跑一次就正常了。'
          '这类问题以后都会在依赖页自动补齐，不用再手工处理。';
      expect(AgentLoop.looksLikePlainQuestion(text), isFalse);
    });
  });

  /// 最后一问被"收尾"吞掉。
  ///
  /// 用户原话："假设我说四个提问，前三个好好的，第四个因为收尾导致并无调用
  /// 提问工具，也就是这个问题变成收尾提出不是提问工具提出。"
  ///
  /// 前三问都走 ask_user（弹卡 + 挂起）。第四问时模型认为活干完了，调
  /// task_complete 把问题写进 summary，循环一命中就 return：界面不弹卡、
  /// 不挂起，追问链在最后一步断掉。[AgentLoop.blockingQuestion] 负责在
  /// 收尾前把这种问题揪出来，把收尾驳回。
  group('blockingQuestion', () {
    test('收尾文案里夹着要用户定的问题 → 揪出那一句', () {
      const text = '前面三项都配好了：脚本已上传、依赖已装、cron 已建。'
          '最后一个问题，通知渠道用哪个？';
      expect(AgentLoop.blockingQuestion(text), '最后一个问题，通知渠道用哪个？');
    });

    test('要用户提供信息（没问号也算）', () {
      const text = '任务建好了。请告诉我 Bark 的推送 key';
      expect(AgentLoop.blockingQuestion(text), '请告诉我 Bark 的推送 key');
    });

    test('客套收尾不算 —— 否则每次干完活都强弹提问卡', () {
      expect(AgentLoop.blockingQuestion('都处理完了，还需要我做别的吗？'), isEmpty);
      expect(AgentLoop.blockingQuestion('搞定，有别的需求随时叫我。'), isEmpty);
      expect(AgentLoop.blockingQuestion('已全部完成，要我继续吗？'), isEmpty);
    });

    test('纯结论、空文本不算', () {
      expect(AgentLoop.blockingQuestion('四个任务都建好了，明早 8 点开跑。'), isEmpty);
      expect(AgentLoop.blockingQuestion(''), isEmpty);
      expect(AgentLoop.blockingQuestion('   '), isEmpty);
    });

    test('只有问号、没有要信息的意思 → 当客套放过', () {
      expect(AgentLoop.blockingQuestion('这样可以吗？'), isEmpty);
    });

    test('客套句在最后、真问题在前面 → 仍能揪出真问题', () {
      const text = '脚本跑通了。环境变量要写进哪个面板？还需要我做别的吗？';
      expect(AgentLoop.blockingQuestion(text), '环境变量要写进哪个面板？');
    });
  });

  /// 模型照抄**界面渲染提问卡的排版**，以为这样就算问了。
  ///
  /// 用户实录（连问三个问题，第二问就断了）：第一问规规矩矩 ask_user，
  /// 第二问气泡里直接是
  ///
  ///     哈哈丰盛就好，一天都有精神！🍳
  ///     ❓第二个问题：最近天气开始转凉，你晚上一般几点睡？
  ///     （日常闲聊第二个问题）
  ///     候选：10点前，养生党 / 11点左右，正常作息 / …
  ///
  /// 过程卡"思考 → 收尾"，零次工具调用，第三问根本没来。
  group('unaskedQuestion（抄提问卡排版）', () {
    const echoed = '哈哈丰盛就好，一天都有精神！🍳\n'
        '❓第二个问题：最近天气开始转凉，你晚上一般几点睡？\n'
        '（日常闲聊第二个问题）\n'
        '候选：10点前，养生党 / 11点左右，正常作息 / 12点以后，夜猫子';

    test('抄排版 → 揪出问题本身（不含 ❓）', () {
      expect(
        AgentLoop.unaskedQuestion(echoed),
        '第二个问题：最近天气开始转凉，你晚上一般几点睡？',
      );
    });

    test('这条正文的最后一行是"候选："，只看最后一句永远判不出来', () {
      // 这就是当初漏掉它的原因：老判据只看最后一句。
      expect(AgentLoop.looksLikePlainQuestion(echoed), isFalse);
      expect(AgentLoop.unaskedQuestion(echoed), isNotEmpty);
    });

    test('没有 ❓、只有"候选：" + 问号 → 照样算手写提问卡', () {
      const text = '你晚上一般几点睡？\n候选：10点前 / 11点左右 / 12点以后';
      expect(AgentLoop.unaskedQuestion(text), '你晚上一般几点睡？');
    });

    test('正常回答里列了候选但没在问话 → 不误伤', () {
      const text = '我把三个方案都试过了。候选：A 最快 / B 最稳 / C 最省。我选了 B。';
      expect(AgentLoop.questionCardEcho(text), isEmpty);
    });

    test('纯结论 → 空', () {
      expect(AgentLoop.unaskedQuestion('任务建好了，明早 8 点跑。'), isEmpty);
      expect(AgentLoop.unaskedQuestion(''), isEmpty);
    });

    test('客套收尾 → 空（不能为了一句"还需要别的吗"去打回重来）', () {
      expect(AgentLoop.unaskedQuestion('都弄好了。还需要我做别的吗？'), isEmpty);
    });

    test('闲聊式提问（没有"要信息"关键词）也要认出来', () {
      // 这就是现场那三个问题的样子：一个 blockingHeads 关键词都没有。
      expect(
        AgentLoop.unaskedQuestion('好嘞，一个一个来。今天早上你吃早餐了吗？'),
        '今天早上你吃早餐了吗？',
      );
    });

    test('阻塞问句在中间也认（退回 blockingQuestion）', () {
      const text = '脚本传上去了。环境变量要写进哪个面板？我先等你确认。';
      expect(AgentLoop.unaskedQuestion(text), '环境变量要写进哪个面板？');
    });
  });

  /// 模型把**我们自己塞进历史的系统簿记**当成了自己的说话模板。
  ///
  /// 用户原话："提问三个最后一个不调用，显示 这一轮调用过的工具：ask_user。"
  /// 那句话是 chat_provider 为了让模型知道"提问要走工具"而加的记录，以前拼在
  /// assistant 消息末尾；模型照着抄，于是第三问既没调工具、也没回答，
  /// 气泡里只剩一句系统内部记录。
  group('echoedBookkeeping', () {
    test('抄簿记原话 → 认出来', () {
      expect(
        AgentLoop.echoedBookkeeping('（这一轮调用过的工具：ask_user）'),
        isTrue,
      );
      expect(
        AgentLoop.echoedBookkeeping('上面那个问题是通过 ask_user 工具问出去的'),
        isTrue,
      );
      expect(
        AgentLoop.echoedBookkeeping('（系统记录 · 上一轮执行到的工具：cron_list）'),
        isTrue,
      );
    });

    test('正常回答不误伤', () {
      expect(AgentLoop.echoedBookkeeping('任务建好了，明早 8 点跑。'), isFalse);
      expect(AgentLoop.echoedBookkeeping('我需要再调一次 ask_user 问你。'), isFalse);
      expect(AgentLoop.echoedBookkeeping(''), isFalse);
    });

    test('剔掉抄来的句子，留下真话', () {
      const text = '好的，脚本已经上传。（这一轮调用过的工具：script_write）';
      expect(AgentLoop.stripBookkeeping(text), '好的，脚本已经上传');
    });

    test('整条都是抄的 → 剔完是空的（这一轮等于白跑）', () {
      expect(
        AgentLoop.stripBookkeeping('（这一轮调用过的工具：ask_user）'),
        isEmpty,
      );
    });
  });
}
