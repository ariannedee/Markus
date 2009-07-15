require 'fastercsv'
require 'auto_complete'


# Manages actions relating to editing and modifying 
# groups.
class GroupsController < ApplicationController
  include GroupsHelper
  # Administrator
  # -
  
  before_filter      :authorize_only_for_admin, :except => [:creategroup,
  :student_interface, :invite_member, :join, :decline_invitation,
  :delete_rejected, :delete_group, :disinvite_member]
   
   auto_complete_for :student, :user_name
   auto_complete_for :assignment, :name
  # TODO filter (except index) to make sure assignment is a group assignment
  

  def student_interface
     @assignment = Assignment.find(params[:id])
     @student = Student.find(session[:uid])
     @grouping = @student.accepted_grouping_for(@assignment.id)
     @pending_groupings = @student.pending_groupings_for(@assignment.id)
     
     if !@grouping.nil?
       @studentmemberships = @grouping.student_memberships
       @group = @grouping.group
    end

     # To list the students not in a group yet
     # We make a list of all students
    @students = @assignment.no_grouping_students_list

     # we make a list of the student not in a group yet AND not invited
     # to this particular group yet
     @students_list = @assignment.can_invite_for(@grouping.id)
  end
  
  # Group management functions ---------------------------------------------
  
  def creategroup
    return unless request.post?
    @assignment = Assignment.find(params[:id])
    @student = Student.find(session[:uid])

    # The student chose to work alone for this assignment.
    # He is then using his personnal repository. 
    # The grouping he belongs to is then linked to a group which has the
    # student's username as groupname
    if params[:workalone]
      # We therefore start by checking if the student's already have an
      # existing group
      @student.create_group_for_working_alone_student(@assignment.id)
    else
      @student.create_autogenerated_name_group(@assignment.id)  
    end
  end
  
  #

  # Invite members to group
  def invite_member
    return unless (request.post?)
    @assignment = Assignment.find(params[:id])
    @student = Student.find(session[:uid]) # student who invites
    @grouping = @student.accepted_grouping_for(@assignment.id) # his group

    @invited = Student.find_by_user_name(params[:invite_member])
    # We first check he isn't already invited in this grouping
    groupings = @invited.pending_groupings_for(@assignment.id)

    if @invited.nil?
      flash[:fail_notice] = "This student doesn't exist."
      return
    end
    if @invited.hidden
      flash[:fail_notice] = "Could not invite this student - this student's account has been disabled"
      return
    end
    if !@grouping.pending?(@invited)
       @invited.invite(@grouping.id)
       flash[:edit_notice] = "Student invited."
    else
       flash[:fail_notice] = "This student is already a pending member of this group!"
    end
  end

  def join
    @assignment = Assignment.find(params[:id])
    @grouping = Grouping.find(params[:grouping_id])
    @user = Student.find(session[:uid])
    @user.join(@grouping.id)
  end
  
  def decline_invitation
    @assignment = Assignment.find(params[:id])
    @grouping = Grouping.find(params[:grouping_id])
    @user = Student.find(session[:uid])
    return unless request.post?
    @grouping.decline_invitation(@user)
  end

  # Remove rejected member
  def delete_rejected
     @assignment = Assignment.find(params[:id])
     membership = StudentMembership.find(params[:membership])
     membership.delete
     membership.save
  end
 
  def disinvite_member
     @assignment = Assignment.find(params[:id])
     membership = StudentMembership.find(params[:membership])
     membership.delete
     membership.save
     flash[:edit_notice] = "Member disinvited"
  end

 
  # Group administration functions -----------------------------------------
  # Verify that all functions below are included in the authorize filter above
    
  def add_member
    return unless (request.post? && params[:student_user_name])
    # add member to the group with status depending if group is empty or not
    grouping = Grouping.find(params[:grouping_id])
    @assignment = Assignment.find(params[:id], :include => [{:groupings => [{:student_memberships => :user, :ta_memberships => :user}, :group]}]) 
    if Student.find_by_user_name(params[:student_user_name]).nil?
      @error = "Could not find student with user name #{params[:student_user_name]}"
      render :action => 'error_single'
      return
    end
    set_membership_status = grouping.student_memberships.empty? ?
    StudentMembership::STATUSES[:inviter] :
    StudentMembership::STATUSES[:accepted]     
    grouping.invite(params[:student_user_name], set_membership_status) 
    grouping.reload
    @grouping = construct_table_row(grouping)
  end
 
  def remove_member
    return unless request.delete?
    
    grouping = Grouping.find(params[:grouping_id])
    member = grouping.student_memberships.find(params[:mbr_id])  # use group as scope
    if member.membership_status == StudentMembership::STATUSES[:inviter]
        inviter = true
    end
    student = member.user  # need to find user name to add to student list
    
    grouping.remove_member(member)

    render :update do |page|
      page.visual_effect(:fade, "mbr_#{params[:mbr_id]}", :duration => 0.5)
      page.delay(0.5) { page.remove "mbr_#{params[:mbr_id]}" }
      # add members back to student list
      page.insert_html :bottom, "student_list",  
        "<li id='user_#{student.user_name}'>#{student.user_name}</li>"
    if inviter
        # find the new inviter
        inviter = grouping.student_memberships.find_by_membership_status(StudentMembership::STATUSES[:inviter])
        # replace the status of the new inviter to 'inviter'
        page.remove "mbr_#{inviter.id}"
        page.insert_html :top, "grouping_#{grouping.id}", 
          :partial => 'groups/manage/member', :locals => {:grouping =>
          grouping, :member => inviter}
      end
    end
  end
  
  def add_group
    @assignment = Assignment.find(params[:id])
    begin
      new_grouping_data = @assignment.add_group(params[:new_group_name])
    rescue Exception => e
      @error = e.message
      render :action => 'error_single'
      return 
    end
    @new_grouping = construct_table_row(new_grouping_data)
  end
  
  def remove_group
    return unless request.delete?
    # TODO remove groups for all assignment or just for the specific assignment?
    # TODO remove submissions in file system?
    grouping = Grouping.find(params[:grouping_id])
    @assignment = grouping.assignment
    @errors = []
    @removed_groupings = []
    if grouping.has_submission?
        @errors.push(grouping.group.group_name)
        render :action => "delete_groupings"
    else
      grouping.delete_grouping
      @removed_groupings.push(grouping)
      render :action => "delete_groupings"
    end
  end

  def rename_group
     @assignment = Assignment.find(params[:id])
     @grouping = Grouping.find(params[:grouping_id]) 
     @group = @grouping.group

     # Checking if a group with this name already exists

    if @groups = Group.find(:first, :conditions => {:group_name =>
     [params[:new_groupname]]})
         existing = true
         groupexist_id = @groups.id
    end
    
    if !existing
        #We update the group_name
        @group.group_name = params[:new_groupname]
        @group.save
        flash[:edit_notice] = "Group name has been updated"
     else

        # We link the grouping to the group already existing

        # We verify there is no other grouping linked to this group on the
        # same assignement
        params[:groupexist_id] = groupexist_id
        params[:assignment_id] = @assignment.id

        if Grouping.find(:all, :conditions => ["assignment_id =
        :assignment_id and group_id = :groupexist_id", {:groupexist_id =>
        groupexist_id, :assignment_id => @assignment.id}])
           flash[:fail_notice] = "This name is already used for this
           assignement"
        else
          @grouping.update_attribute(:group_id, groupexist_id)
          flash[:edit_notice] = "Group name has been changed"
        end
     end
  end

  def valid_grouping
     @assignment = Assignment.find(params[:id])
     grouping = Grouping.find(params[:grouping_id])
     grouping.validate_grouping
  end
  
  def populate
    @assignment = Assignment.find(params[:id], :include => [{:groupings => [{:student_memberships => :user, :ta_memberships => :user}, :group]}])   
    @groupings = @assignment.groupings
    @table_rows = {}
    @groupings.each do |grouping|
      # construct_table_row is in the groups_helper.rb
      @table_rows[grouping.id] = construct_table_row(grouping)     
    end
  end

  def manage
    @all_assignments = Assignment.all(:order => :id)
    @assignment = Assignment.find(params[:id], :include => [{:groupings => [{:student_memberships => :user, :ta_memberships => :user}, :group]}])   
    @groupings = @assignment.groupings
    # Returns a hash where s.id is the key, and student record is the value
    @ungrouped_students = @assignment.ungrouped_students
    @tas = Ta.all
  end
  
  # Assign TAs to Groupings via a csv file
  def ta_groupings_csv_upload
    if !request.post?
      redirect_to :index
      return
    end
    
    flash[:invalid_lines] = []
    Grouping.assign_tas_by_csv(params[:ta_groupings_file], params[:assignment_id])
    redirect_to :index   
  end
  
  # Allows the user to upload a csv file listing groups.
  def csv_upload
    if request.post? && !params[:group].blank?
      @assignment = Assignment.find(params[:id])
   	  num_update = 0
      flash[:invalid_lines] = []  # store lines that were not processed
      
      # Loop over each row, which lists the members to be added to the group.
      FasterCSV.parse(params[:group][:grouplist]) do |row|
		if add_csv_group(row, @assignment) == nil
		    flash[:invalid_lines] << row.join(",")
		else
       		num_update += 1
     	end
	   end
	   flash[:upload_notice] = "#{num_update} group(s) added."
     end
  end
  
  # Helper method to add the listed members.
  def add_csv_group (group, assignment)

  	return nil if group.length <= 0
	  @grouping = Grouping.new
      @grouping.assignment_id = assignment.id
      # If a group with this name already exist, link the grouping to
      # this group. else create the group
      if Group.find(:first, :conditions => {:group_name => group[0]})
         @group = Group.find(:first, :conditions => {:group_name => group[0]})
	  else
         @group = Group.new
         @group.group_name = group[0]	
         @group.save
      end

      @grouping.group_id = @group.id
      @grouping.save
      # Add first member to group.
      student = Student.find(:first, :conditions => {:user_name => group[1]})
      member = @grouping.add_member(student)
      member.membership_status = StudentMembership::STATUSES[:inviter]
      member.save
      for i in 2..group.length do
        student = Student.find(:first, :conditions => {:user_name =>group[i]})
        @grouping.add_member(student)
      end
  end
  
  def download_grouplist
    assignment = Assignment.find(params[:id])

    #get all the groups
    groupings = assignment.groupings #FIXME: optimize with eager loading

    file_out = FasterCSV.generate do |csv|
       groupings.each do |grouping|
         group_array = [grouping.group.group_name]
         # csv format is group_name, user1_name, user2_name, ... etc
         grouping.memberships.all(:include => :user).each do |member|
            group_array.push(member.user.user_name);
         end
         csv << group_array
       end
     end

    send_data(file_out, :type => "text/csv", :disposition => "inline")
  end

  def use_another_assignment_groups
    @target_assignment = Assignment.find(params[:id])
    source_assignment = Assignment.find(params[:clone_groups_assignment_id])
      
    if source_assignment.nil?
      flash[:fail_notice] = "Could not find source assignment for cloning groups"
    end
    if @target_assignment.nil?
      flash[:fail_notice] = "Could not find target assignment for cloning groups"
    end
      
    # First, destroy all groupings for the target assignment
    @target_assignment.groupings.each do |grouping|
      grouping.destroy
    end
      
    # Next, we need to set the target assignments grouping settings to match
    # the source assignment

    @target_assignment.group_min = source_assignment.group_min
    @target_assignment.group_max = source_assignment.group_max
    @target_assignment.student_form_groups = source_assignment.student_form_groups
    @target_assignment.group_name_autogenerated = source_assignment.group_name_autogenerated
    @target_assignment.group_name_displayed = source_assignment.group_name_displayed
    
    source_groupings = source_assignment.groupings

    source_groupings.each do |old_grouping|
      #create the groupings
      new_grouping = Grouping.new
      new_grouping.assignment_id = @target_assignment.id
      new_grouping.group_id = old_grouping.group_id
      new_grouping.save
      #create the memberships - both TA and Student memberships
      old_memberships = old_grouping.memberships
      old_memberships.each do |old_membership|
        new_membership = Membership.new
        new_membership.user_id = old_membership.user_id
        new_membership.membership_status = old_membership.membership_status
        new_membership.grouping = new_grouping
        new_membership.type = old_membership.type
        new_membership.save
      end
    end

    flash[:edit_notice] = "Groups created"
  end

  # TODO:  This method is massive, and does way too much.  Whatever happened
  # to single-responsibility?
  def global_actions 
    @assignment = Assignment.find(params[:id], :include => [{:groupings => [{:student_memberships => :user, :ta_memberships => :user}, :group]}])   
    

    if params[:submit_type] == 'random_assign'
      begin 
        if params[:graders].nil?
          raise "You must select at least one grader for random assignment"
        end
        randomly_assign_graders(params[:graders], @assignment.groupings)
        @groupings_data = construct_table_rows(@assignment.groupings)
        render :action => "modify_groupings"
        return
      rescue Exception => e
        @error = e.message
        render :action => 'error_single'
        return
      end
    end
    
    global_action = params[:global_actions]
    grouping_ids = params[:groupings]
    if params[:groupings].nil? or params[:groupings].size ==  0
      flash[:error] = "You need to select at least one group."
    end
    @grouping_data = {}
    @groupings = []
    
    case params[:global_actions]
      when "delete"
        @removed_groupings = []
        @errors = []
        groupings = Grouping.find(grouping_ids)
        groupings.each do |grouping|
          if grouping.has_submission?
            @errors.push(grouping.group.group_name)
	  else
            grouping.delete_grouping
            @removed_groupings.push(grouping)
	  end
        end
        render :action => "delete_groupings"
        return
      
      when "invalid"
        groupings = Grouping.find(grouping_ids)
        groupings.each do |grouping|
           grouping.invalidate_grouping
        end
        @groupings_data = construct_table_rows(groupings)
        render :action => "modify_groupings"
        return      
      
      when "valid"
        groupings = Grouping.find(grouping_ids)
        groupings.each do |grouping|
           grouping.validate_grouping
        end
        @groupings_data = construct_table_rows(groupings)
        render :action => "modify_groupings"
        return
        
      when "assign"
        @groupings_data = assign_tas_to_groupings(grouping_ids, params[:graders])
        render :action => "modify_groupings"
        return
        
      when "unassign"
        @groupings_data = unassign_tas_to_groupings(grouping_ids, params[:graders])
        render :action => "modify_groupings"
        return
    end
  end


end