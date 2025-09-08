// tcp-ia-full.cc
// Agent/TCP/FullTcp/IAFull (Tcl登録名)

#ifndef lint
static const char rcsid[] =
    "@(#) $Header: (tcp-ia-full.cc)$";
#endif

#include "ip.h"
#include "tcp-full.h" // 基底クラス FullTcpAgent のため
#include "flags.h"

class TcpIAFullAgent : public FullTcpAgent {
 public:
    TcpIAFullAgent();
    virtual void delay_bind_init_all(); 
    virtual int delay_bind_dispatch(const char *varName, const char *localName, TclObject *tracer);
    virtual int command(int argc, const char*const* argv);
    //double advwnd_ia_;
 protected:
    double advwnd_ia_;
};

// Tclへのクラス登録
static class TcpIAFullAgentClass : public TclClass {
public:
    TcpIAFullAgentClass() : TclClass("Agent/TCP/FullTcp/IAFull") {} // Tclから呼び出す際のパス名
    TclObject* create(int, const char*const*) {
        return (new TcpIAFullAgent());
    }
} class_tcp_ia_full_agent_instance; // ユニークなインスタンス名


TcpIAFullAgent::TcpIAFullAgent() : FullTcpAgent() {
    bind("advwnd_ia_", &advwnd_ia_); // Tcl変数 "advwnd_ia_" をC++メンバ advwnd_ia_ にバインド
    advwnd_ia_ = 0.0; // 初期値 (通常はTclスクリプトから設定)
    // this->wnd_ (TcpAgentのメンバ) は基底クラスのコンストラクタで初期化される
}

void TcpIAFullAgent::delay_bind_init_all() {
    delay_bind_init_one("advwnd_ia_");
    FullTcpAgent::delay_bind_init_all();
}

int TcpIAFullAgent::delay_bind_dispatch(const char *varName, const char *localName, TclObject *tracer) {
    if (delay_bind(varName, localName, "advwnd_ia_", &advwnd_ia_, tracer)) return TCL_OK;
    return FullTcpAgent::delay_bind_dispatch(varName, localName, tracer);
}

int TcpIAFullAgent::command(int argc, const char*const* argv) {
    if (argc == 3) {
        if (strcmp(argv[1], "active") == 0) {
            int active_state = atoi(argv[2]);
            if (active_state == 0) {
                // 広告ウィンドウを0に設定 (フローを非アクティブ化)
                // this->wnd_ は TcpAgent から継承されたメンバで、通常セグメント単位。
                // tcph->wnd() に反映させるために、ここでは0 (パケット) を設定する意図。
                // FullTcpAgentがACKを生成する際、この this->wnd_ を参照することを期待。
                this->wnd_ = 0.0;
                fprintf(stderr, "#####################\n");
                fprintf(stderr, "%f %s: active 0, this->wnd_ set to 0.0\n", Scheduler::instance().clock(), name());
            } else if (active_state == 1) {
                this->wnd_ = advwnd_ia_;
                fprintf(stderr, "====================\n");
                fprintf(stderr, "%f %s: active 1, advwnd_ia_ is %f, this->wnd_ set to %f\n",
                Scheduler::instance().clock(), name(), advwnd_ia_, this->wnd_); // ★デバッグプリント追加
            }else {
                Tcl::instance().resultf("%s: invalid argument to active command", name());
                return (TCL_ERROR);
            }

            // ウィンドウ変更を対向に通知するためACK送信を試みる
            if (state_ >= TCPS_ESTABLISHED || state_ == TCPS_SYN_RECEIVED) {
                flags_ |= TF_ACKNOW; // ACK送信要求フラグ
                send_much(1, REASON_NORMAL, maxburst_); // 強制的に送信処理を試みる
            }
            return (TCL_OK);
        }
    }
    // "active" 以外のコマンドは基底クラス (FullTcpAgent) に処理を委譲
    // これにより "req-rtx" などの ahtcp 固有コマンドは引き続き機能する
    return (FullTcpAgent::command(argc, argv));
}