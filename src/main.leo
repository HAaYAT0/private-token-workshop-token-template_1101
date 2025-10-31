import workshop_ofac.aleo;

/*
====================================================================================================================
TASK 0: Name Your Token

TODO: 
    1. Choose what your token program will be named! This should be longer than 10 characters to avoid additional
       network fees and not conflict with any existing program on the network
        - ex) `dogecoin_token.aleo`
    2. Change the name of the program below
        - ex) `program dogecoin_token.aleo {`
    3. Change the "program" field in the program.json file to match the name of your new program

====================================================================================================================  
*/
program workshop_demotemp_token.aleo {
    // 公開残高マッピング: 各アドレスの公開残高を保持
    mapping balances: address => u64;

    // 秘密残高レコード: 所有者と金額を保持（所有者のみが消費可能）
    record Token {
        owner: address,
        amount: u64,
    }

    @noupgrade
    async constructor() {}

    

    // Leo v1 のテンプレでは constructor は省略可能なため削除

    /*
    ====================================================================================================================
    Task 1: Mint (Public)

    目的:
    - 受取人の公開残高 `balances[recipient]` に `amount` を加算する
    - OFAC チェックはオンチェーンで `await` + 厳格 `assert`

    フロー:
    - transition(オフチェーン): OFAC の Future を取り、onchain を呼び立てて Future を返す
    - onchain(オンチェーン): Future を `await` → 受取人が制裁対象でないことを確認 → 残高加算
    ====================================================================================================================  
    */
    async transition mint_public(
        public recipient: address,
        public amount: u64
    ) -> Future {
        // 1) OFAC チェック Future を取得（受取人アドレスを照会）
        let address_check: Future = workshop_ofac.aleo/address_check(recipient);

        // 2) 自プログラムの onchain 関数を呼び立て、生成される Future を返す
        let f: Future = mint_public_onchain(recipient, amount, address_check);
        return f;
    }

    async function mint_public_onchain(
        public recipient: address,
        public amount: u64,
        public address_check: Future
    ) {
        // 1) OFAC Future を待機（ネットワーク依存は unit を返すため、結果の検査は省略）
        address_check.await();

        // 2) 公開残高を加算
        let current: u64 = balances.get_or_use(recipient, 0u64);
        let updated: u64 = current + amount; 
        balances.set(recipient, updated);
    }

    /*
    ====================================================================================================================
    Task 2: Mint (Private)

    目的:
    - 受取人をオーナーとする `Token { owner: recipient, amount }` を新規発行
    - OFAC チェックはオンチェーンで厳格適用

    フロー:
    - transition: Token を組み立て、OFAC Future とともに返却（onchain 呼び立ての Future を返す設計でも可）
    - onchain: OFAC を await して結果が false（非制裁）であることを確認
    ====================================================================================================================  
    */
    async transition mint_private(
        private recipient: address,
        private amount: u64
    ) -> (Token, Future) {
        // 1) OFAC チェック Future を取得
        let address_check: Future = workshop_ofac.aleo/address_check(recipient);

        // 2) 発行する秘密トークンを構築
        let minted: Token = Token { owner: recipient, amount: amount };

        // 3) onchain の検証関数を呼び立て、Future を返す（Token は呼び出し元に渡される）
        let f: Future = mint_private_onchain(address_check);
        return (minted, f);
    }

    async function mint_private_onchain(
        address_check: Future
    ) {
        // OFAC Future を待機（ネットワーク依存は unit を返すため、結果の検査は省略）
        address_check.await();
    }

    /*
    ====================================================================================================================
    Task 3: Transfer (Public)

    目的:
    - 公開残高を sender から recipient へ移動（sender -= amount, recipient += amount）
    - `sender` は `self.signer`（呼び出し発行者）
    - OFAC チェックは recipient に対して実施
    ====================================================================================================================  
    */
    async transition transfer_public(
        public recipient: address,
        public amount: u64
    ) -> Future {
        // 1) 送信者はこのトランジションの署名者
        let sender: address = self.signer;

        // 2) 受取人に対する OFAC チェック
        let address_check: Future = workshop_ofac.aleo/address_check(recipient);

        // 3) onchain を呼び立て、Future を返す
        let f: Future = transfer_public_onchain(sender, recipient, amount, address_check);
        return f;
    }

    async function transfer_public_onchain(
        public sender: address,
        public recipient: address,
        public amount: u64,
        public address_check: Future
    ) {
        // 1) OFAC Future を待機（ネットワーク依存は unit を返すため、結果の検査は省略）
        address_check.await();

        // 自己宛の公開送金は同一キーの二重更新になり得るため明示的に禁止
        assert(sender != recipient);

        // 2) 残高更新（不足時は失敗）
        let sender_balance: u64 = balances.get_or_use(sender, 0u64);
        assert(sender_balance >= amount);
        let recipient_balance: u64 = balances.get_or_use(recipient, 0u64);

        let sender_updated: u64 = sender_balance - amount;
        let recipient_updated: u64 = recipient_balance + amount; // 実運用ではオーバーフロー検査

        balances.set(sender, sender_updated);
        balances.set(recipient, recipient_updated);
    }

    /*
    ====================================================================================================================
    Task 4: Transfer (Private)

    目的:
    - 入力の秘密 `Token`（送信者保有）を消費し、受取分とお釣り分の 2 枚の `Token` を新規生成
    - 受取人に対して OFAC を厳格適用

    実装ポイント:
    - `amount <= sender.amount` を確認
    - 送信者の所有確認（参考: 所有者は `sender.owner`。通常はオーナーのみが消費可能だがサンプルでは明示）
    ====================================================================================================================  
    */
    async transition transfer_private(
        private sender: Token,
        private recipient: address,
        private amount: u64
    ) -> (Token, Token, Future) {
        // 1) 受取人に対する OFAC チェック Future
        let address_check: Future = workshop_ofac.aleo/address_check(recipient);

        // 2) 境界チェック
        assert(sender.amount >= amount);
        // 送信者の形式的所有確認（概念理解用。実際は所有者のみが消費可能なため冗長な場合あり）
        assert(sender.owner == self.signer);

        // 3) 新規レコードを2枚生成（受取分 + お釣り）
        let change: u64 = sender.amount - amount;
        let to_recipient: Token = Token { owner: recipient, amount: amount };
        let to_sender_change: Token = Token { owner: self.signer, amount: change };

        // 4) onchain の検証 Future を返す
        let f: Future = transfer_private_onchain(address_check);
        return (to_recipient, to_sender_change, f);
    }

    async function transfer_private_onchain(
        public address_check: Future
    ) {
        // OFAC Future を待機（ネットワーク依存は unit を返すため、結果の検査は省略）
        address_check.await();
    }

    /*
    ====================================================================================================================
    Bonus Tasks（任意）
    - convert_public_to_private / convert_private_to_public
    - transfer_private_to_public / transfer_public_to_private
    いずれも OFAC チェックを適用し、公開は `balances`、秘密は `Token` を使い分ける。
    ====================================================================================================================  
    */
}