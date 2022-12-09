class MessagesController < ApplicationController
  def index
    #レコード取得
    @user = current_user
    messages = @user.received_messages.order(updated_at: :DESC)
    ids = @user.message_destinations.where(delete_flag: 0).pluck(:message_id)
    if @is_send_box = params[:box] == "send"
      messages = @user.messages.where(id: ids).order(updated_at: :DESC)
    elsif @is_trash_box = params[:box] == "trash"
      removed_ids = @user.message_destinations.where(delete_flag: 1).pluck(:message_id)
      messages = messages.where(id: removed_ids)
    else
      messages = messages.where(id: ids)
    end
    @messages = messages

    #検索クエリ
    @q = params[:query]
    if @q
      q = @q.split
      ids = []
      @messages.each do |message|
        #プレーンテキストに変換→検索
        ids.push(message.id) if q.all?{|x| message.plaintext_body.include?(x) || message.title.include?(x)}
      end
      @messages = @messages.where(id: ids)
    end

    @messages = @messages.includes(:favorites, :user).page(params[:page]).per(@user.config.number_of_displayed_items)
  end

  def new
    user = current_user
    @message = user.messages.new
    @user_list = User.where(is_invalid: nil)
  end

  def create
    user = current_user
    message = user.messages.new(message_params)
    if message.save
      destination_ids = params[:message][:destination].split.map{|i| i.to_i}
      editor_ids = params[:message][:editor].split.map{|i| i.to_i}
      destinations = []
      now = Time.zone.now
      destination_ids.each do |receiver_id|
        # unless receiver_id == current_user.id
        #   receiver = message.message_destinations.new(receiver_id: receiver_id)
        #   receiver.is_editable = true if editor_ids.include?(receiver_id)
        #   receiver.save
        # end
        destinations.push({receiver_id: receiver_id, is_editable: (receiver_id == user.id ? true : editor_ids.include?(receiver_id)), created_at: now, updated_at: now})
      end
      message.message_destinations.insert_all!(destinations)
      #送信者は自動的に受信者・編集者に追加
      message.message_destinations.create(receiver_id: current_user.id, is_editable: true) unless destination_ids.include?(user.id)
      flash[:notice] = "メッセージを作成しました。"
      redirect_to message
    end

  end

  def show
    @message = Message.find(params[:id])
    @receivers = @message.receivers
    @editors = @message.editors

    #宛先に含まれているか、送信者でないと表示されない
    return raise Forbidden unless @message.user == current_user || @receivers.include?(current_user)

    @new_comment = @message.comments.new
    @comments = @message.comments.order(created_at: :DESC).page(params[:page]).per(current_user.config.number_of_displayed_comments)

    #未読→既読の設定
    current_time = Time.zone.now
    @message.receiver_model.update(finished_reading: current_time) if @message.already_read_flag.nil?

    #未表示のコメント・本文がハイライトされる仕様
    last_view = @message.receiver_model.last_viewing
    @viewed_comment = @message.receiver_model.viewed_comment
    @message.receiver_model.update(viewed_comment: @message.number_of_comments, last_viewing: current_time)
    @unread_after_update = last_view < @message.update_content_at unless last_view.nil? || @message.update_content_at.nil?

    #宛先リストに表示される上限数
    @limit_view_receivers = 10
  end

  def edit
    @message = Message.find(params[:id])
    @user_list = User.where(is_invalid: nil)
    @receivers = @message.receivers.where(id: @message.message_destinations.pluck(:receiver_id))
    @editors = @receivers.where(id: @message.message_destinations.where(is_editable: true).pluck(:receiver_id))

    #編集者か、送信者でないと表示されない
    raise Forbidden unless @message.user == current_user || @editors.include?(current_user)
  end

  def update
    message = Message.find(params[:id])
    user = message.user
    message_updated_date = message.updated_at

    if message.update(message_params)
      #内容が更新されていれば最終更新をマーク
      if message.updated_at > message_updated_date
        message.update(update_content_at: message.updated_at, last_update_user_id: current_user.id)
      end

      new_destination_ids = params[:message][:destination].split.map{|i| i.to_i}
      new_editor_ids = params[:message][:editor].split.map{|i| i.to_i}

      #新しい宛先が指定されたら追加する
      destination_ids = message.message_destinations.pluck(:receiver_id)
      add_destinations = []
      now = Time.zone.now
      (new_destination_ids - destination_ids).each do |receiver_id|
        # receiver = message.message_destinations.new(receiver_id: receiver_id)
        # receiver.is_editable = true if new_editor_ids.include?(receiver_id)
        # receiver.save
        add_destinations.push({receiver_id: receiver_id, is_editable: (receiver_id == user.id ? true : new_editor_ids.include?(receiver_id)), created_at: now, updated_at: now})
      end
      message.message_destinations.insert_all!(add_destinations) if add_destinations.length > 1

      #既存の宛先が無ければ削除する（送信者自身は削除されない）
      # (destination_ids - new_destination_ids).each do |receiver_id|
      #   message.message_destinations.find_by(receiver_id: receiver_id).destroy unless receiver_id == message.user_id
      # end
      delete_destinations = (destination_ids - new_destination_ids)
      delete_destinations.delete(user.id)
      message.message_destinations.where(receiver_id: delete_destinations).delete_all if delete_destinations.length > 1
      

      #編集権限を付与されたユーザーを更新
      editor_ids = message.message_destinations.where(is_editable: true).pluck(:receiver_id)
      # (new_editor_ids - editor_ids).each do |editor_id|
      #   message.message_destinations.find_by(receiver_id: editor_id).update(is_editable: true)
      # end
      
      message.message_destinations.where(receiver_id: (new_editor_ids - editor_ids)).update_all(is_editable: true)

      #編集権限を解除されたユーザーを更新（送信者自身は削除されない）
      # (editor_ids - new_editor_ids).each do |editor_id|
      #   message.message_destinations.find_by(receiver_id: editor_id).update(is_editable: false) unless editor_id == message.user_id
      # end
      delete_permission_edit = (editor_ids - new_editor_ids)
      delete_permission_edit.delete(user.id)
      message.message_destinations.where(receiver_id: delete_permission_edit).update_all(is_editable: false)


      #添付ファイルの削除
      remove_file_ids = params[:message][:existing_files]
      unless remove_file_ids.nil?
        remove_file_ids.each do |file_id|
          message.attachments.find(file_id).purge
        end
      end

      flash[:notice] = "メッセージを変更しました。"
      redirect_to message
    end
  end

  def destroy
    message = Message.find(params[:id])
    flash[:notice] = "“#{message.title}”は完全に削除されました。"
    message.destroy
    redirect_to messages_path
  end

  def receivers
    @message = Message.find(params[:id])
    @destinations = @message.message_destinations.includes(:receiver)
    raise Forbidden unless @message.receivers.include?(current_user)
  end

  def trash
    message = Message.find(params[:id])
    message.message_destinations.find_by(receiver_id: current_user.id).update(delete_flag: 1)
    flash[:notice] = "“#{message.title}”をごみ箱に移動しました。"
    redirect_to messages_path(box: "trash")
  end

  def restore
    message = Message.find(params[:id])
    message.message_destinations.find_by(receiver_id: current_user.id).update(delete_flag: 0)
    flash[:notice] = "“#{message.title}”を受信箱に戻しました。"
    redirect_to message_path
  end

  private

	def message_params
		params.require(:message).permit(:title, :body, :is_commentable, :confirmation_flag, attachments: [])
	end

end
